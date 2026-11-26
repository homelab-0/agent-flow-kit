package router

import (
	"context"
	"encoding/json"
	"io/fs"
	"math"
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

// ProbePools works out the state of every subscription pool now: live
// usage where the provider reports it, recent session activity otherwise,
// and recent failure signals on top.
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
	var codexQ quota
	codexMode := ""
	wg.Add(3)
	go func() { defer wg.Done(); gw = probeGateway(ctx, e) }()
	go func() { defer wg.Done(); codexQ = probeCodexQuota(e) }()
	go func() {
		defer wg.Done()
		if e.CodexLoginMode != nil && nonEmpty(e.path("AFK_CODEX_AUTH_FILE", ".codex/auth.json")) {
			codexMode = e.CodexLoginMode(ctx)
		}
	}()
	wg.Wait()
	harnesses["litellm_gateway"] = gw

	binds := accountBindings(e, harnesses, codexMode)
	bound := func(h, pool string) bool { return contains(binds[pool], h) }

	since := e.Now.Add(-300 * time.Minute)
	c5 := countRecent(filepath.Join(e.Home, ".claude", "projects"), since)
	// Codex sessions count against the ChatGPT plan only when Codex is
	// signed in with the plan, not with an API key (metered usage).
	x5 := 0
	if !bound("codex", "api-metered") || bound("codex", "openai-plus") {
		x5 = countRecent(codexSessionsDir(e), since)
	}
	a5 := countRecentDirs(filepath.Join(e.Home, ".gemini", "antigravity-cli", "brain"), since)
	o5 := countRecent(filepath.Join(e.Home, ".local", "share", "opencode"), since)
	p5 := countRecent(filepath.Join(e.Home, ".pi", "agent", "sessions"), since)
	g5 := countRecent(filepath.Join(e.Home, ".grok"), since)
	xai5 := g5
	if bound("opencode", "xai-grok") {
		xai5 += o5
	}
	if bound("opencode", "openai-plus") {
		x5 += o5
	}
	if bound("pi", "openai-plus") {
		x5 += p5
	}

	sig := readSignals(e.SignalsPath())
	openaiMt := maxInt64(mtime(e.path("AFK_CODEX_AUTH_FILE", ".codex/auth.json")), mtime(e.path("AFK_OPENCODE_AUTH_FILE", ".local/share/opencode/auth.json")))
	claudeMt := mtime(e.path("AFK_CLAUDE_CREDS_FILE", ".claude/.credentials.json"))
	grokMt := mtime(e.path("AFK_GROK_AUTH_FILE", ".grok/auth.json"))

	pc := poolCalc{cat: cat, sig: sig, now: e.Now.Unix(), gatewayOn: gw.Online, harnesses: harnesses, binds: binds}
	pools := map[string]Pool{
		"anthropic-max":    pc.calc("anthropic-max", c5, false, []string{"claude"}, quota{}, claudeMt),
		"openai-plus":      pc.calc("openai-plus", x5, false, []string{"codex"}, codexQ, openaiMt),
		"antigravity-pool": pc.calc("antigravity-pool", a5, false, []string{"agy"}, quota{}, 0),
		"xai-grok":         pc.calc("xai-grok", xai5, false, []string{"grok", "opencode"}, quota{}, grokMt),
		"opencode-free":    pc.calc("opencode-free", o5, false, []string{"opencode"}, quota{}, 0),
		"litellm-local":    pc.calc("litellm-local", 0, true, []string{"claude", "opencode"}, quota{}, 0),
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
	if harnesses["grok"].Installed && pools["xai-grok"].QuotaSource == "unauthenticated" {
		alerts = append(alerts, map[string]any{
			"pool": "xai-grok", "pool_id": "xai-grok", "harnesses": []string{"grok"},
			"reason": "grok CLI installed on disk but not signed in", "reauth_command": "grok login",
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
	return &Probe{Schema: PoolsSchema, Harnesses: harnesses, AuthAlerts: alerts, UnavailableModels: unavailable, Pools: pools, Bindings: binds}
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
	PlanType        *string  `json:"plan_type,omitempty"`
	ExtraUsageOn    bool     `json:"extra_usage_enabled,omitempty"`
	FetchedEpochRaw int64    `json:"-"`
}

// --- signals ---------------------------------------------------------------

type poolSignal struct {
	UsedPct        *float64 `json:"used_pct"`
	Capacity5h     *float64 `json:"capacity_5h"`
	DegradedReason *string  `json:"degraded_reason"`
	DegradedKind   *string  `json:"degraded_kind"`
	UpdatedAt      *string  `json:"updated_at"`
	UpdatedEpoch   *int64   `json:"updated_epoch"`
	TTL            *int64   `json:"ttl_sec"`
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
	feeding   map[string][]string
}

func (pc *poolCalc) calc(pid string, sessions int, local bool, defaultH []string, live quota, authMtime int64) Pool {
	meta, ok := pc.cat.Pools[pid]
	if !ok && pid == "opencode-free" {
		meta = PoolMeta{Provider: "OpenCode Free Tier", CostClass: "free", PoolTier: "free", FiveHourSession: f64(200)}
	}
	sg, kind, active := activeSignal(pc.sig, pid, authMtime, pc.now)
	bound := pc.binds[pid]

	// The first positive capacity wins; zero or negative would divide by
	// zero below, so it is skipped.
	capacity := 50.0
	pos := func(v *float64) bool { return v != nil && *v > 0 }
	switch {
	case active && pos(sg.Capacity5h):
		capacity = *sg.Capacity5h
	case pos(pc.sig.Pools[pid].Capacity5h):
		capacity = *pc.sig.Pools[pid].Capacity5h
	case pos(meta.FiveHourSession):
		capacity = *meta.FiveHourSession
	}
	unauth := pid == "xai-grok" && !active && len(bound) == 0

	var used float64
	var src string
	switch {
	case active && sg.UsedPct != nil:
		k := kind
		if k == "" {
			k = "manual"
		}
		used, src = *sg.UsedPct, "runtime_signal:"+k
	case unauth:
		used, src = 100, "unauthenticated"
	case live.OK:
		used, src = live.UsedPct, live.Source
	case local:
		used, src = 100, "gateway_probe"
		if pc.gatewayOn {
			used = 0
		}
	default:
		used = math.Min(jqRound(float64(sessions)*100/capacity), 98)
		src = "local_5h_activity"
	}
	headroom := 100 - used
	remaining := math.Floor(capacity * headroom / 100)
	state := "available"
	switch {
	case local && !pc.gatewayOn:
		state = "offline"
	case pid == "opencode-free" && !pc.harnesses["opencode"].Installed:
		state = "offline"
	case unauth:
		state = "offline"
	case active && kind == "auth":
		state = "auth_required"
	case used >= 90:
		state = "exhausted"
	case used >= 75:
		state = "warning"
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
	p := Pool{
		PoolID: pid, Provider: provider, PoolTier: tier, CostClass: cc, State: state,
		Capacity5h: f64(capacity), Remaining5h: f64(remaining), UsedPct: f64(used), HeadroomPct: f64(headroom),
		QuotaSource: src, WeeklyUsedPct: live.SevenDayPct, FiveHourUsedPct: live.FiveHourPct,
		FableWeeklyUsedPct: live.FableWeeklyPct, ResetsAt: live.ResetsAt,
	}
	if active {
		if kind != "" {
			k := kind
			p.DegradedKind = &k
		}
		p.DegradedReason = sg.DegradedReason
	}
	return p
}

// jqRound rounds half away from zero, as jq does.
func jqRound(v float64) float64 { return math.Round(v) }

// --- local activity -----------------------------------------------------------

// countRecent counts session files (.json, .jsonl) changed since the given
// time, at most five directories deep, as the bash probe's find does.
func countRecent(dir string, since time.Time) int {
	// WalkDir doesn't follow a symlinked root; resolve it first.
	if r, err := filepath.EvalSymlinks(dir); err == nil {
		dir = r
	}
	n := 0
	base := strings.Count(filepath.Clean(dir), string(filepath.Separator))
	_ = filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		depth := strings.Count(filepath.Clean(p), string(filepath.Separator)) - base
		if d.IsDir() {
			if depth >= 5 {
				return fs.SkipDir
			}
			return nil
		}
		if depth > 5 || !d.Type().IsRegular() {
			return nil
		}
		if !strings.HasSuffix(p, ".jsonl") && !strings.HasSuffix(p, ".json") {
			return nil
		}
		if fi, err := d.Info(); err == nil && fi.ModTime().After(since) {
			n++
		}
		return nil
	})
	return n
}

// countRecentDirs counts the subdirectories changed since the given time.
func countRecentDirs(dir string, since time.Time) int {
	ents, err := os.ReadDir(dir)
	if err != nil {
		return 0
	}
	n := 0
	for _, d := range ents {
		if !d.IsDir() {
			continue
		}
		if fi, err := d.Info(); err == nil && fi.ModTime().After(since) {
			n++
		}
	}
	return n
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
func accountBindings(e ProbeEnv, h map[string]HarnessState, codexMode string) map[string][]string {
	out := map[string][]string{}
	add := func(pool, harness string) {
		if !contains(out[pool], harness) {
			out[pool] = append(out[pool], harness)
		}
	}
	if exists(e.path("AFK_CLAUDE_CREDS_FILE", ".claude/.credentials.json")) || isDir(filepath.Join(e.Home, ".claude")) {
		add("anthropic-max", "claude")
	}
	if nonEmpty(e.path("AFK_CODEX_AUTH_FILE", ".codex/auth.json")) {
		if codexMode == "apikey" {
			add("api-metered", "codex")
		} else {
			add("openai-plus", "codex")
		}
	}
	if h["agy"].Installed {
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

func isDir(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && fi.IsDir()
}
