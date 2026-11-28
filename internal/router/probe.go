package router

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// ProbeEnv is everything the pool probe reads. Tests replace it.
type ProbeEnv struct {
	Home   string
	Getenv func(string) string
	Now    time.Time
	// GatewayURL is the model gateway (LiteLLM or compatible); "" for none.
	GatewayURL string
	// LocalURLs are where to look for inference engines on this machine
	// (none: don't look). Only loopback addresses are probed.
	LocalURLs []string
	// GPU names this machine's GPU ("" when it can't tell); nil skips it.
	// It is asked only when a local engine answers.
	GPU func(ctx context.Context) string
	// Installed reports whether a CLI is installed and answers. Nil uses
	// the cached --version check (VerifyBinaries).
	Installed func(name string) bool
	// HTTP is used for the gateway's model list (nil: a client with
	// short timeouts).
	HTTP *http.Client
	// Live turns the gateway probe on. Off, pools come from local
	// activity and signals only.
	Live bool
	// CodexLoginMode reports how Codex is signed in, from Codex's own
	// `codex login status`: "chatgpt" (the plan), "apikey" (metered), or
	// "" when it can't tell. AFK never opens Codex's auth.json to find
	// out. Nil means unknown.
	CodexLoginMode func(ctx context.Context) string
	// SignedIn asks a CLI's own status command whether it is signed in.
	// known is false when the CLI has no such command or didn't answer;
	// what is on disk decides then. Nil asks nothing.
	SignedIn func(ctx context.Context, harness string) (signedIn, known bool)
}

func (e ProbeEnv) getenv(k string) string {
	if e.Getenv == nil {
		return ""
	}
	return e.Getenv(k)
}

func (e ProbeEnv) path(env, def string) string {
	if v := e.getenv(env); v != "" {
		return v
	}
	return filepath.Join(e.Home, def)
}

// SignalsPath is where pool and model failure signals are kept.
func (e ProbeEnv) SignalsPath() string {
	return e.path("AFK_ROUTER_SIGNALS_FILE", ".config/afk/pool-signals.json")
}

// probeHarnesses are the CLIs the pool probe looks for.
var probeHarnesses = []string{"claude", "codex", "agy", "grok", "opencode", "pi", "devin"}

// ProbePools works out the state of every subscription pool now: usage
// where the plan's own CLI reported it, no figure at all otherwise, and
// recent failure signals on top.
func ProbePools(ctx context.Context, cat *Catalog, e ProbeEnv) *Probe {
	if e.Now.IsZero() {
		e.Now = time.Now()
	}
	if e.HTTP == nil {
		e.HTTP = &http.Client{Timeout: 4 * time.Second}
	}
	harnesses := map[string]HarnessState{}
	var mu sync.Mutex
	var wg sync.WaitGroup
	for _, h := range probeHarnesses {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ok := false
			if e.Installed != nil {
				ok = e.Installed(h)
			}
			mu.Lock()
			harnesses[h] = HarnessState{Installed: ok}
			mu.Unlock()
		}()
	}
	var gw HarnessState
	var local []LocalEngine
	var codexQ quota
	codexMode := ""
	wg.Add(4)
	go func() { defer wg.Done(); gw = probeGateway(ctx, e) }()
	go func() { defer wg.Done(); local = probeLocal(ctx, e) }()
	go func() { defer wg.Done(); codexQ = probeCodexQuota(e) }()
	go func() {
		defer wg.Done()
		if e.CodexLoginMode != nil && nonEmpty(codexAuthPath(e)) {
			codexMode = e.CodexLoginMode(ctx)
		}
	}()
	// The CLIs with a status command of their own say whether they are
	// signed in. Only a clear "no" is kept.
	signedOut := map[string]bool{}
	if e.SignedIn != nil {
		for _, h := range planHome {
			wg.Add(1)
			go func() {
				defer wg.Done()
				if in, known := e.SignedIn(ctx, h); known && !in {
					mu.Lock()
					signedOut[h] = true
					mu.Unlock()
				}
			}()
		}
	}
	wg.Wait()
	harnesses["litellm_gateway"] = gw
	gpu := ""
	if len(local) > 0 && e.GPU != nil {
		gpu = e.GPU(ctx)
	}

	binds := accountBindings(e, harnesses, codexMode, signedOut)

	sig := readSignals(e.SignalsPath())
	// Claude's plan usage as its last one-shot run through AFK reported it.
	claudeQ, _ := readPlanUsage(e.UsagePath(), "anthropic-max", e.Now)
	// A newer login file clears a sign-in failure signal for its pool.
	openaiMt := mtime(codexAuthPath(e))
	claudeMt := mtime(claudeCredsPath(e))
	grokMt := mtime(e.path("AFK_GROK_AUTH_FILE", ".grok/auth.json"))

	pc := poolCalc{cat: cat, sig: sig, now: e.Now.Unix(), gatewayOn: gw.Online, harnesses: harnesses, binds: binds, signedOut: signedOut}
	pools := map[string]Pool{
		"anthropic-max":    pc.calc("anthropic-max", false, []string{"claude"}, claudeQ, claudeMt),
		"openai-plus":      pc.calc("openai-plus", false, []string{"codex"}, codexQ, openaiMt),
		"antigravity-pool": pc.calc("antigravity-pool", false, []string{"agy"}, quota{}, 0),
		"xai-grok":         pc.calc("xai-grok", false, []string{"grok", "opencode"}, quota{}, grokMt),
		"opencode-free":    pc.calc("opencode-free", false, []string{"opencode"}, quota{}, 0),
		"litellm-local":    pc.calc("litellm-local", true, []string{"claude", "opencode"}, quota{}, 0),
		LocalPool:          localPool(local),
	}

	for id, p := range pools {
		p.Pacing = pace(p, e.Now)
		pools[id] = p
	}

	alerts := []any{}
	ids := make([]string, 0, len(pools))
	for id := range pools {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		p := pools[id]
		if p.State != "auth_required" {
			continue
		}
		feeding := pc.feeding[id]
		primary := "unknown"
		if len(feeding) > 0 {
			primary = feeding[0]
		}
		reason := "Authentication token expired or signed out"
		if p.DegradedReason != nil {
			reason = *p.DegradedReason
		}
		alerts = append(alerts, map[string]any{
			"pool": id, "pool_id": id, "harnesses": feeding, "reason": reason, "reauth_command": reauth(primary),
		})
	}
	for _, id := range ids {
		h := planHome[id]
		if h == "" || !harnesses[h].Installed || pools[id].QuotaSource != SourceSignedOut {
			continue
		}
		alerts = append(alerts, map[string]any{
			"pool": id, "pool_id": id, "harnesses": []string{h},
			"reason": h + " CLI installed on disk but not signed in", "reauth_command": reauth(h),
		})
	}

	unavailable := map[string]any{}
	for m, v := range sig.Unavailable {
		ttl := v.TTL
		if ttl == 0 {
			ttl = 3600
		}
		if e.Now.Unix()-v.UpdatedEpoch < ttl {
			unavailable[m] = v
		}
	}
	return &Probe{Schema: PoolsSchema, Harnesses: harnesses, AuthAlerts: alerts, UnavailableModels: unavailable, Pools: pools, Bindings: binds, Local: local, LocalGPU: gpu, at: e.Now}
}

func reauth(h string) string {
	switch h {
	case "codex":
		return "codex login"
	case "claude":
		return "claude auth login"
	case "grok":
		return "grok login"
	case "agy":
		return "agy login"
	}
	return h + " login"
}

// quota is a live usage reading from a provider.
type quota struct {
	OK              bool     `json:"ok"`
	Source          string   `json:"source"`
	UsedPct         float64  `json:"used_pct"`
	FiveHourPct     *float64 `json:"five_hour_pct"`
	SevenDayPct     *float64 `json:"seven_day_pct"`
	FableWeeklyPct  *float64 `json:"fable_weekly_pct"`
	ResetsAt        *string  `json:"resets_at"`
	ResetsAtEpoch   *float64 `json:"resets_at_epoch,omitempty"`
	Window          string   `json:"window,omitempty"`
	PlanType        *string  `json:"plan_type,omitempty"`
	ExtraUsageOn    bool     `json:"extra_usage_enabled,omitempty"`
	FetchedEpochRaw int64    `json:"-"` // when the reading was taken (unix seconds), 0 unknown
}

// --- signals ---------------------------------------------------------------

type poolSignal struct {
	UsedPct        *float64 `json:"used_pct"`
	DegradedReason *string  `json:"degraded_reason"`
	DegradedKind   *string  `json:"degraded_kind"`
	UpdatedAt      *string  `json:"updated_at"`
	UpdatedEpoch   *int64   `json:"updated_epoch"`
	TTL            *int64   `json:"ttl_sec"`
	// until is when the signal stops applying (unix seconds), 0 when it
	// holds until cleared.
	until int64
}

type modelSignal struct {
	Reason       string `json:"reason"`
	UpdatedAt    string `json:"updated_at"`
	UpdatedEpoch int64  `json:"updated_epoch"`
	TTL          int64  `json:"ttl_sec"`
}

type signals struct {
	Pools       map[string]poolSignal  `json:"pools"`
	Unavailable map[string]modelSignal `json:"unavailable_models"`
	// fileTime is when the signals file was last written: the time given
	// to a signal whose own timestamp can't be read.
	fileTime int64
}

// readSignals reads the signals file. A missing, truncated or hand-edited
// file means no signals; it never takes routing down.
func readSignals(path string) signals {
	var s signals
	b, err := os.ReadFile(path)
	if err != nil {
		return signals{}
	}
	// A file that doesn't decode is ignored whole: a half-read file must
	// not quarantine a model or a pool.
	if json.Unmarshal(b, &s) != nil {
		return signals{}
	}
	if fi, err := os.Stat(path); err == nil {
		s.fileTime = fi.ModTime().Unix()
	}
	return s
}

var (
	reAuthKind  = regexp.MustCompile(`401|unauthorized|revoked|invalidated oauth|refresh token|not logged in`)
	reQuotaKind = regexp.MustCompile(`429|rate_limit|rate limit|quota|out_of_credits|exhausted`)
)

// activeSignal is a pool's failure signal while it still applies: until
// its TTL runs out, and for a sign-in failure until the login is renewed.
func activeSignal(s signals, pid string, authMtime, now int64) (*poolSignal, string, bool) {
	sg, ok := s.Pools[pid]
	if !ok {
		return nil, "", false
	}
	var up *int64
	if sg.UpdatedEpoch != nil {
		up = sg.UpdatedEpoch
	} else if sg.UpdatedAt != nil {
		if t, err := time.Parse(time.RFC3339, *sg.UpdatedAt); err == nil {
			v := t.Unix()
			up = &v
		} else {
			// An unreadable timestamp is not "1970": the signal is dated
			// when the file was last written, so it still expires, and a
			// sign-in signal still clears when the login is renewed.
			v := s.fileTime
			up = &v
		}
	}
	if up == nil {
		// No time on it: it holds until someone clears it.
		kind := ""
		if sg.DegradedKind != nil {
			kind = *sg.DegradedKind
		}
		return &sg, kind, true
	}
	reason := ""
	if sg.DegradedReason != nil {
		reason = strings.ToLower(*sg.DegradedReason)
	}
	kind := "transient"
	switch {
	case sg.DegradedKind != nil:
		kind = *sg.DegradedKind
	case reAuthKind.MatchString(reason):
		kind = "auth"
	case reQuotaKind.MatchString(reason):
		kind = "quota"
	}
	var ttl int64 = 900
	switch {
	case sg.TTL != nil:
		ttl = *sg.TTL
	case kind == "auth":
		ttl = 86400
	case kind == "quota":
		ttl = 3600
	}
	if kind == "auth" && authMtime > *up {
		return nil, "", false
	}
	if now-*up >= ttl {
		return nil, "", false
	}
	sg.until = *up + ttl
	return &sg, kind, true
}

// --- pool arithmetic --------------------------------------------------------

type poolCalc struct {
	cat       *Catalog
	sig       signals
	now       int64
	gatewayOn bool
	harnesses map[string]HarnessState
	binds     map[string][]string
	signedOut map[string]bool // CLIs whose own status command says signed out
	feeding   map[string][]string
}

// Where a pool's figures come from when no CLI reported them.
const (
	// SourceUnknown: nothing reported this plan's usage, so there is no
	// figure. AFK never estimates one.
	SourceUnknown = "unknown"
	// SourceSignedOut: the plan's own CLI is installed but not signed in.
	SourceSignedOut = "unauthenticated"
)

// signInPools are the plan pools whose own CLI AFK can tell is signed out
// from what that CLI keeps on disk, and that CLI.
var signInPools = map[string]string{"xai-grok": "grok", "antigravity-pool": "agy"}

// calc works out one pool. The used and headroom figures are set only
// from a reading the plan's own CLI reported (live); without one they are
// nil and the source says why. Nothing here is estimated.
func (pc *poolCalc) calc(pid string, local bool, defaultH []string, live quota, authMtime int64) Pool {
	meta, ok := pc.cat.Pools[pid]
	if !ok && pid == "opencode-free" {
		meta = PoolMeta{Provider: "OpenCode Free Tier", CostClass: "free", PoolTier: "free"}
	}
	sg, kind, active := activeSignal(pc.sig, pid, authMtime, pc.now)
	bound := pc.binds[pid]
	// Not signed in: the plan's own CLI says so, or (for a CLI with no
	// status command) it has no login on disk.
	_, signIn := signInPools[pid]
	unauth := !active && len(bound) == 0 && (signIn || pc.signedOut[planHome[pid]]) && pc.harnesses[planHome[pid]].Installed

	var used *float64
	var src string
	setAside := false
	state := "available"
	switch {
	case active && (kind == "auth" || sg.UsedPct != nil):
		setAside = true
		// A failed run set this pool aside. That is a state, not a usage
		// figure: how much of the plan is used is still whatever was
		// last reported, which a failure doesn't tell.
		k := kind
		if k == "" {
			k = "manual"
		}
		src = "runtime_signal:" + k
		switch {
		case kind == "auth":
			state = "auth_required"
		case sg.UsedPct == nil || *sg.UsedPct >= 90:
			state = "exhausted"
		case *sg.UsedPct >= 75:
			state = "warning"
		}
	case unauth:
		src, state = SourceSignedOut, "offline"
	case live.OK:
		u := live.UsedPct
		used, src = &u, live.Source
		switch {
		case u >= 90:
			state = "exhausted"
		case u >= 75:
			state = "warning"
		}
	case local:
		src = "gateway_probe"
	default:
		src = SourceUnknown
	}
	switch {
	case local && !pc.gatewayOn:
		state = "offline"
	case pid == "opencode-free" && !pc.harnesses["opencode"].Installed:
		state = "offline"
	}
	if pc.feeding == nil {
		pc.feeding = map[string][]string{}
	}
	if len(bound) > 0 {
		pc.feeding[pid] = bound
	} else {
		pc.feeding[pid] = defaultH
	}
	provider := meta.Provider
	if provider == "" {
		provider = pid
	}
	tier := meta.PoolTier
	if tier == "" {
		tier = "standard"
	}
	cc := meta.CostClass
	if cc == "" {
		cc = "subscription"
	}
	p := Pool{PoolID: pid, Provider: provider, PoolTier: tier, CostClass: cc, State: state, QuotaSource: src}
	if used != nil {
		p.UsedPct, p.HeadroomPct = used, f64(100-*used)
	}
	// The reading's windows and reset time describe the pool only while the
	// reading is what the figure comes from: under a failed run's signal they
	// would contradict the state shown beside them.
	if live.OK && src == live.Source {
		p.WeeklyUsedPct, p.FiveHourUsedPct = live.SevenDayPct, live.FiveHourPct
		p.FableWeeklyUsedPct, p.ResetsAt = live.FableWeeklyPct, live.ResetsAt
		p.Window = live.Window
		if live.FetchedEpochRaw > 0 {
			p.observed = time.Unix(live.FetchedEpochRaw, 0)
		}
	}
	if p.ResetsAt == nil && live.OK && live.ResetsAtEpoch != nil && src == live.Source {
		r := time.Unix(int64(*live.ResetsAtEpoch), 0).UTC().Format(time.RFC3339)
		p.ResetsAt = &r
	}
	if active {
		if kind != "" {
			k := kind
			p.DegradedKind = &k
		}
		p.DegradedReason = sg.DegradedReason
	}
	if setAside && state != "available" {
		p.SetAside = true
		if sg.until > 0 {
			u := time.Unix(sg.until, 0).UTC().Format(time.RFC3339)
			p.SetAsideUntil = &u
		}
	}
	return p
}

func mtime(p string) int64 {
	fi, err := os.Stat(p)
	if err != nil {
		return 0
	}
	return fi.ModTime().Unix()
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

// --- account bindings -------------------------------------------------------

// accountBindings maps each pool to the CLIs signed in to it. Every check
// here looks only at whether a login file exists and is not empty: AFK
// never opens a credential file. How Codex is signed in (the ChatGPT plan
// or an API key) comes from Codex's own status command.
//
// A third-party CLI (opencode, pi) signed in with a vendor plan would share
// that plan's pool, but which plan is written only inside its credential
// file, so AFK no longer binds them to vendor pools: opencode draws on its
// own free pool, and pi on none.
func accountBindings(e ProbeEnv, h map[string]HarnessState, codexMode string, signedOut map[string]bool) map[string][]string {
	out := map[string][]string{}
	add := func(pool, harness string) {
		if !contains(out[pool], harness) {
			out[pool] = append(out[pool], harness)
		}
	}
	if !signedOut["claude"] && (exists(claudeCredsPath(e)) || isDir(claudeDir(e))) {
		add("anthropic-max", "claude")
	}
	if !signedOut["codex"] && nonEmpty(codexAuthPath(e)) {
		// Three answers: the plan, an API key, or Codex couldn't say (slow,
		// missing or unfamiliar output). The last binds Codex to neither:
		// its sessions are counted against no pool and its plan pool shows
		// no figure, so a metered login is never taken for the plan.
		// Codex still routes; only the pool arithmetic waits for an answer.
		switch codexMode {
		case "chatgpt":
			add("openai-plus", "codex")
		case "apikey":
			add("api-metered", "codex")
		}
	}
	// Antigravity keeps its sign-in under its own folder; installed with
	// nothing there is not signed in.
	if h["agy"].Installed && dirHasEntries(filepath.Join(e.Home, ".gemini", "antigravity-cli")) {
		add("antigravity-pool", "agy")
	}
	if nonEmpty(e.path("AFK_GROK_AUTH_FILE", ".grok/auth.json")) {
		add("xai-grok", "grok")
	}
	if h["opencode"].Installed || exists(e.path("AFK_OPENCODE_AUTH_FILE", ".local/share/opencode/auth.json")) {
		add("opencode-free", "opencode")
	}
	for k := range out {
		sort.Strings(out[k])
	}
	return out
}

// nonEmpty: a regular file bigger than an empty JSON object ("{}", which a
// CLI that signed out may leave behind). Its contents are never read.
func nonEmpty(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular() && fi.Size() > 4
}

func readJSONFile(path string, v any) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return json.Unmarshal(b, v) == nil
}

func exists(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.Mode().IsRegular()
}

// dirHasEntries: a directory with anything in it. Nothing is opened.
func dirHasEntries(p string) bool {
	ents, err := os.ReadDir(p)
	return err == nil && len(ents) > 0
}

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}
