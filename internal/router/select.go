package router

import (
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Input is one routing question.
type Input struct {
	Stage         string
	Risk          string
	Round         int
	Surfaces      []string
	DiffLines     int
	BuilderFamily string // the family that built the work, for cross-family review

	// OnlyHarnesses limits the choice to these CLIs; empty allows all.
	OnlyHarnesses []string
	// OnlyPool limits the choice to routes served by this pool; empty
	// allows all.
	OnlyPool string
	// ExcludePools leaves out the routes these pools serve.
	ExcludePools []string
	// OnlyEngineURL limits the choice to the local engine at this address.
	OnlyEngineURL string

	GatewayURL         string
	AllowMetered       bool
	PreferFree         bool
	AllowFreeReviewers bool
	SecurityModels     []string // entitled specialist security models

	Now      time.Time
	CarrySec int64 // a measured score older than this is stale (default 14 days)
}

// DiscoveredModel is a model a CLI reported itself (opencode models, agy
// models, ...), not in the catalog.
type DiscoveredModel struct {
	ID              string   `json:"id"`
	Harness         string   `json:"harness"`
	LaunchClass     string   `json:"launch_class"`
	EntitlementPool string   `json:"entitlement_pool"`
	CostClass       string   `json:"cost_class"`
	IsFree          bool     `json:"is_free"`
	Model           string   `json:"model"`
	CanonicalModel  string   `json:"canonical_model"`
	ModelFamily     string   `json:"model_family"`
	WindowTokens    *float64 `json:"window_tokens"`
	SupportedEffort []string `json:"supported_efforts"`
	Capabilities    struct {
		Reasoning bool `json:"reasoning"`
		Toolcall  bool `json:"toolcall"`
	} `json:"capabilities"`
	Benchmarks map[string]Benchmark `json:"benchmarks"`
}

// BasisUnrated is the benchmark basis of a model its CLI reported that
// the catalog has no score for. It ranks at UnratedScore, which is a
// place in the order, not a measurement, and is never shown as a score.
const BasisUnrated = "unrated"

// UnratedScore is where an unrated model ranks.
const UnratedScore = 75.0

// MarshalJSON writes an unrated route's scores as null: the default it
// ranks at is a place in the order, and a reader of the JSON must not
// take it for a measurement.
func (r Route) MarshalJSON() ([]byte, error) {
	type plain Route
	if r.BenchmarkBasis != BasisUnrated {
		return json.Marshal(plain(r))
	}
	return json.Marshal(struct {
		plain
		BenchmarkScore *float64 `json:"benchmark_score"`
		EffectiveScore *float64 `json:"effective_score"`
	}{plain: plain(r)})
}

// Route is the router's decision.
type Route struct {
	Stage            string   `json:"stage"`
	Round            int      `json:"round"`
	TaskClass        string   `json:"task_class"`
	Risk             string   `json:"risk"`
	CandidateID      string   `json:"candidate_id,omitempty"`
	Harness          string   `json:"harness"`
	LaunchClass      string   `json:"launch_class"`
	Model            string   `json:"model"`
	CanonicalModel   string   `json:"canonical_model"`
	ModelFamily      string   `json:"model_family"`
	SpecialistDomain *string  `json:"specialist_domain,omitempty"`
	CostClass        string   `json:"cost_class"`
	IsFree           bool     `json:"is_free"`
	Effort           string   `json:"effort"`
	BaseEffort       string   `json:"base_effort"`
	EffortEscalated  bool     `json:"effort_escalated"`
	EffortReason     string   `json:"effort_reason"`
	SupportedEfforts []string `json:"supported_efforts"`
	WindowTokens     *float64 `json:"window_tokens"`
	EntitlementPool  string   `json:"entitlement_pool"`
	PoolState        string   `json:"pool_state,omitempty"`
	PoolUsedPct      *float64 `json:"pool_used_pct,omitempty"`
	PoolHeadroomPct  *float64 `json:"pool_headroom_pct"`
	// PoolQuotaSource is where the pool figures came from: a reading the
	// CLI reported (codex_rate_limits, claude_rate_limit_event), a failure
	// signal (runtime_signal:<kind>), the gateway probe, unauthenticated,
	// or unknown. Only a reading carries figures.
	PoolQuotaSource   string  `json:"pool_quota_source,omitempty"`
	PoolUsageNote     string  `json:"pool_usage_note,omitempty"`
	BenchmarkName     string  `json:"benchmark_name"`
	BenchmarkScore    float64 `json:"benchmark_score"`
	BenchmarkBasis    string  `json:"benchmark_basis"`
	BenchmarkLive     bool    `json:"benchmark_live"`
	BenchmarkSyncedAt *string `json:"benchmark_synced_at"`
	EffectiveScore    float64 `json:"effective_score"`
	CrossFamilyReview *bool   `json:"cross_family_review,omitempty"`
	RouterSource      string  `json:"router_source"`
	LitellmBaseURL    *string `json:"litellm_base_url"`
	// The gateway a gateway route goes through, as config names it, and
	// the engine and host behind it (labels from config).
	GatewayName string `json:"gateway_name,omitempty"`
	GatewayKind string `json:"gateway_kind,omitempty"`
	Engine      string `json:"engine,omitempty"`
	EngineHost  string `json:"engine_host,omitempty"`
	// A local model's engine address, this machine's GPU and whether a
	// model is loaded.
	EngineURL   *string `json:"engine_url,omitempty"`
	EngineGPU   string  `json:"engine_gpu,omitempty"`
	EngineState string  `json:"engine_state,omitempty"`
	AuthAlerts  []any   `json:"auth_alerts"`
	Reason      string  `json:"reason"`

	// Your ratings of this CLI and model on this kind of task, when there
	// are enough of them to count, and the points they moved the score.
	OutcomeRuns       *int     `json:"outcome_runs,omitempty"`
	OutcomeAdjustment *float64 `json:"outcome_adjustment,omitempty"`

	// Where the route's plan window is heading, and the points pacing
	// moved the score (0 with route.pacing off).
	Pacing           *Pacing  `json:"pacing,omitempty"`
	PacingAdjustment *float64 `json:"pacing_adjustment,omitempty"`

	// Set on the fallback route only.
	NoEligibleCandidate  bool              `json:"no_eligible_candidate,omitempty"`
	CandidatesConsidered *int              `json:"candidates_considered,omitempty"`
	InstalledHarnesses   *[]string         `json:"installed_harnesses,omitempty"`
	PoolStates           map[string]string `json:"pool_states,omitempty"`
}

// ServedBy returns, for each installed CLI that can run the model (named
// as that CLI names it, or by its canonical name), that CLI's name for it:
// from the catalog and from the models the CLIs reported, as routing sees
// them.
func (r *Router) ServedBy(model string, installed []string, allowMetered bool) map[string]string {
	out := map[string]string{}
	for _, c := range withReported(r.candidates(allowMetered), r.Probe) {
		if !r.launchable(c) {
			continue
		}
		if r.Probe != nil && !r.Probe.signedIn(c.Harness, c.EntitlementPool) {
			continue
		}
		if (c.Model == model || c.CanonicalModel == model) && contains(installed, c.Harness) {
			if _, seen := out[c.Harness]; !seen {
				out[c.Harness] = c.Model
			}
		}
	}
	return out
}

// PoolFor is the pool a CLI draws on to run a model natively, from the
// catalog ("" when the catalog doesn't list it). A pinned route carries no
// pool of its own; this is the pool its failures are recorded against.
func (r *Router) PoolFor(harness, model string) string {
	var cands []Candidate
	if r.Catalog != nil {
		cands = r.Catalog.Candidates
	}
	for _, c := range cands {
		if c.Harness == harness && (c.Model == model || c.CanonicalModel == model) && !strings.HasSuffix(c.LaunchClass, "-gateway") {
			return c.EntitlementPool
		}
	}
	// A model only a CLI reported (opencode models, agy models).
	for _, d := range r.Discovered {
		if d.Harness == harness && (d.Model == model || d.CanonicalModel == model) && !strings.HasSuffix(d.LaunchClass, "-gateway") {
			return d.EntitlementPool
		}
	}
	return ""
}

// launchable reports whether AFK can launch the candidate at all. Which
// CLI you use with which login is your choice; the only limits are
// technical and credential safety: a gateway route runs on claude only
// (the one CLI AFK can point at a gateway with the gateway's own key),
// and a plan login is never sent to a gateway.
func (r *Router) launchable(c Candidate) bool {
	cclass := c.CostClass
	if cclass == "" && r.Catalog != nil {
		cclass = r.Catalog.Pools[c.EntitlementPool].CostClass
	}
	if cclass == "" {
		cclass = "subscription"
	}
	viaGateway := strings.HasSuffix(c.LaunchClass, "-gateway")
	return !viaGateway || (cclass != "subscription" && c.Harness == "claude")
}

// planHome is the CLI whose own login each plan pool is.
var planHome = map[string]string{
	"anthropic-max": "claude", "openai-plus": "codex", "xai-grok": "grok", "antigravity-pool": "agy",
}

// signedIn reports whether a CLI can draw on a plan pool: its own plan
// always (the pool's state covers sign-in), another vendor's plan only
// when the CLI is signed in to it. Unknown bindings hold nothing back.
func (p *Probe) signedIn(harness, pool string) bool {
	home, isPlan := planHome[pool]
	if !isPlan || home == harness || p.Bindings == nil {
		return true
	}
	return contains(p.Bindings[pool], harness)
}

// headroomWeight is how many score points one percent of reported plan
// headroom is worth: a full plan leads an almost spent one by about three
// points, enough to move work off a plan that is running out.
const headroomWeight = 0.0325

// IsFallback reports whether nothing passed the eligibility rules.
func (r Route) IsFallback() bool { return r.RouterSource == "fallback-default" }

// Router routes with one catalog and one view of the pools.
type Router struct {
	Catalog    *Catalog
	Probe      *Probe
	Discovered []DiscoveredModel
	// Outcomes are your ratings of past runs. Nil leaves scores to the
	// benchmarks.
	Outcomes map[OutcomeKey]OutcomeStats
	// Pacing leans routes toward a measured window that is about to reset
	// unused, and away from one that will run out first (route.pacing).
	Pacing bool
}

// probeOrder is the order the pool probe lists the CLIs in.
var probeOrder = []string{"claude", "codex", "opencode", "grok", "agy", "pi", "devin"}

var (
	reFrontier    = regexp.MustCompile(`astra|fable|mythos|daybreak|opus|gemini-4-carbon|gpt-6|(^|/)grok-4\.7$`)
	reDynKeep     = regexp.MustCompile(`gpt-6-astra$|gpt-6\.1-sol$|gpt-5\.3-codex-spark$|claude-fable|claude-mythos|daybreak-blue|claude-opus-5-5(-high)?$|claude-sonnet-5-5(-high)?$|gemini-4-argon-high$|gemini-3\.8-flash-high$|^grok-4\.6$`)
	reStdTier     = regexp.MustCompile(`sonnet|sol|flash|luna`)
	reAgyCarbon   = regexp.MustCompile(`^gemini-4-carbon`)
	defaultEffort = []string{"low", "medium", "high"}
)

func effortRank(e string) int {
	switch e {
	case "low":
		return 1
	case "medium":
		return 2
	case "high":
		return 3
	case "xhigh":
		return 4
	case "max", "ultra":
		return 5
	}
	return 2
}

func rankToEffort(r int) string {
	switch {
	case r <= 1:
		return "low"
	case r == 2:
		return "medium"
	case r == 3:
		return "high"
	case r == 4:
		return "xhigh"
	}
	return "max"
}

// clampEffort picks the supported level closest to the target, the higher
// one on a tie.
func clampEffort(target int, supported []string) string {
	if supported == nil {
		supported = defaultEffort
	}
	ideal := rankToEffort(target)
	for _, s := range supported {
		if s == ideal {
			return ideal
		}
	}
	best, bestD, bestR := "", math.MaxInt, 0
	for _, s := range supported {
		r := effortRank(s)
		d := r - target
		if d < 0 {
			d = -d
		}
		if d < bestD || (d == bestD && r > bestR) {
			best, bestD, bestR = s, d, r
		}
	}
	if best == "" {
		return "high"
	}
	return best
}

type effortChoice struct {
	effort, base, reason string
	escalated            bool
}

func (in Input) resolveEffort(tc, candDefault string, supported []string) effortChoice {
	if supported != nil && len(supported) == 0 {
		return effortChoice{} // a model with no effort setting (local models)
	}
	st, rk, dl := in.Stage, in.Risk, in.DiffLines
	var base int
	switch {
	case tc == "frontier_synthesis" || rk == "critical":
		base = 4
	case tc == "security" || tc == "architecture" || tc == "coding_complex" || rk == "high":
		base = 3
	case strings.HasPrefix(st, "review") && rk == "medium":
		base = 3
	case rk == "low" && dl > 0 && dl < 80 && (tc == "research" || tc == "coding_standard" || tc == "coding_review" || tc == "webdev"):
		base = 2
	case rk == "low" && (tc == "research" || tc == "coding_standard"):
		base = 2
	default:
		if candDefault == "" {
			candDefault = "medium"
		}
		base = effortRank(candDefault)
	}
	roundBump := 0
	if in.Round == 2 {
		roundBump = 1
	} else if in.Round >= 3 {
		roundBump = 2
	}
	diffBump := 0
	if strings.HasPrefix(st, "review") && dl >= 250 && roundBump == 0 {
		diffBump = 1
	}
	target := base + roundBump + diffBump
	if target > 5 {
		target = 5
	}
	reason := "benchmark_task_" + tc
	switch {
	case roundBump > 0:
		reason = "auto_escalated_round_" + strconv.Itoa(in.Round)
	case diffBump > 0:
		reason = "auto_escalated_large_diff_" + strconv.Itoa(dl) + "L"
	case tc == "frontier_synthesis":
		reason = "critical_frontier_synthesis"
	case tc == "security":
		reason = "security_deep_audit"
	}
	return effortChoice{
		effort: clampEffort(target, supported), base: clampEffort(base, supported),
		escalated: roundBump+diffBump > 0, reason: reason,
	}
}

// candidates is the catalog plus the discovered models that qualify.
func (r *Router) candidates(allowMetered bool) []Candidate {
	out := append([]Candidate(nil), r.Catalog.Candidates...)
	for _, d := range r.Discovered {
		if !d.Capabilities.Toolcall {
			continue
		}
		if !(d.CostClass == "free" || d.CostClass == "subscription" || (allowMetered && d.CostClass == "api-metered")) {
			continue
		}
		// The catalog already has these flagships.
		if (d.Harness == "agy" && reAgyCarbon.MatchString(d.Model)) ||
			(d.Harness == "grok" && d.Model == "grok-4.7") ||
			(d.Harness == "codex" && (d.Model == "gpt-6-astra" || d.Model == "gpt-6.1-sol")) {
			continue
		}
		if !d.IsFree && !reDynKeep.MatchString(d.Model) {
			continue
		}
		tier := "strong"
		if reStdTier.MatchString(d.Model) {
			tier = "standard"
		}
		effort := "medium"
		if d.Capabilities.Reasoning {
			effort = "high"
		}
		sup := d.SupportedEffort
		if sup == nil {
			sup = []string{"medium"}
			if d.Capabilities.Reasoning {
				sup = []string{"low", "medium", "high"}
			}
		}
		bm := map[string]Benchmark{}
		for k, v := range d.Benchmarks {
			name := v.Name
			if name == "" {
				name = v.Source
			}
			if name == "" {
				name = "Dynamic Eval"
			}
			// Only the score and its name carry over, as in the bash router.
			bm[k] = Benchmark{Score: v.Score, Name: name, scoreText: v.scoreText}
		}
		free := d.IsFree
		out = append(out, Candidate{
			ID: d.ID, Harness: d.Harness, LaunchClass: d.LaunchClass, EntitlementPool: d.EntitlementPool,
			CostClass: d.CostClass, IsFree: &free, Tier: tier, Model: d.Model, CanonicalModel: d.CanonicalModel,
			ModelFamily: d.ModelFamily, Effort: effort, SupportedEfforts: sup, WindowTokens: d.WindowTokens,
			BridgedOAuth: (d.Harness == "opencode" && d.CostClass == "subscription") ||
				(d.Harness == "agy" && strings.HasPrefix(d.Model, "claude-")),
			Benchmarks: bm,
		})
	}
	return out
}

// Select returns the best route for the input. When nothing qualifies it
// returns the fallback route (IsFallback), which a caller must not launch
// blindly: it may name a CLI outside OnlyHarnesses.
func (r *Router) Select(in Input) Route {
	if in.Round < 1 {
		in.Round = 1
	}
	if in.CarrySec <= 0 {
		in.CarrySec = 1209600
	}
	if in.Now.IsZero() {
		in.Now = time.Now()
	}
	probe := r.Probe
	if probe == nil {
		probe = &Probe{Harnesses: map[string]HarnessState{}, Pools: map[string]Pool{}, ProbeFailed: true}
	}
	alerts := probe.AuthAlerts
	if alerts == nil {
		alerts = []any{}
	}
	tc := TaskClass(in.Stage, in.Risk, in.Surfaces, in.Round, in.DiffLines)
	isReview := tc == "coding_review" || strings.HasPrefix(in.Stage, "review") || in.Stage == "approve"
	reviewish := tc == "coding_review" || strings.HasPrefix(in.Stage, "review")

	sec := map[string]bool{}
	for _, m := range in.SecurityModels {
		sec[strings.ToLower(strings.ReplaceAll(m, " ", ""))] = true
	}
	// A CLI that lists a restricted model has access to it on its own
	// account only; it says nothing about another CLI's account.
	discoveredHas := func(harness, sub string) bool {
		for _, d := range r.Discovered {
			if d.Harness == harness && strings.Contains(strings.ToLower(d.Model), sub) {
				return true
			}
		}
		for _, m := range probe.Harnesses[harness].Models {
			if strings.Contains(strings.ToLower(m), sub) {
				return true
			}
		}
		return false
	}
	mythos := func(h string) bool {
		return sec["all"] || sec["mythos"] || sec["claude-mythos"] || discoveredHas(h, "mythos")
	}
	daybreak := func(h string) bool {
		return sec["all"] || sec["daybreak"] || sec["daybreak-blue"] || sec["gpt-daybreak-blue"] || discoveredHas(h, "daybreak")
	}

	only := map[string]bool{}
	for _, h := range in.OnlyHarnesses {
		only[h] = true
	}
	poolState := func(id string) string { return probe.Pools[id].State }
	subsUnderPressure := poolState("anthropic-max") != "available" &&
		poolState("antigravity-pool") != "available" && poolState("xai-grok") != "available"

	cands := withReported(append(r.candidates(in.AllowMetered), r.localCandidates(probe)...), probe)
	var routes []Route
	for _, c := range cands {
		if !probe.Harnesses[c.Harness].Installed {
			continue
		}
		pool, ok := probe.Pools[c.EntitlementPool]
		if !ok {
			pool = defaultPool(c.CostClass)
		}
		cclass := c.CostClass
		if cclass == "" {
			cclass = pool.CostClass
		}
		if cclass == "" {
			cclass = "subscription"
		}
		isFree := c.IsFree != nil && *c.IsFree
		bm, hasBM := c.Benchmarks[tc]
		var baseScore float64
		scoreText := "75.0"
		switch {
		case hasBM && bm.Score != nil:
			baseScore, scoreText = *bm.Score, bm.ScoreText()
		case c.Benchmarks["coding_complex"].Score != nil:
			cc := c.Benchmarks["coding_complex"]
			baseScore, scoreText = *cc.Score, cc.ScoreText()
		default:
			baseScore = 75.0
		}
		bname := bm.Name
		if bname == "" {
			bname = "Public Leaderboard Aggregate"
		}

		switch c.RequiresEntitlement {
		case "":
		case "mythos":
			if !mythos(c.Harness) {
				continue
			}
		case "daybreak-blue":
			if !daybreak(c.Harness) {
				continue
			}
		default:
			continue
		}
		if c.ScopedQuota == "fable" && pool.FableWeeklyUsedPct != nil && *pool.FableWeeklyUsedPct >= 90 {
			continue
		}
		if v := probe.UnavailableModels[c.Model]; v != nil && v != false {
			continue
		}
		// Reviewer floor: no free or local model reviews work that may
		// merge unattended.
		if isReview && !in.AllowFreeReviewers && (isFree || cclass == "free" || cclass == "local" || c.RequiresGateway) {
			continue
		}
		// Frontier models stay off known small edits and low/medium intake.
		if reFrontier.MatchString(c.Model) &&
			((in.Risk == "low" && in.DiffLines > 0 && in.DiffLines < 80 &&
				(tc == "research" || tc == "coding_standard" || tc == "coding_review" || tc == "webdev")) ||
				(in.Stage == "intake" && (in.Risk == "low" || in.Risk == "medium"))) {
			continue
		}
		if cclass == "api-metered" && !in.AllowMetered {
			continue
		}
		// Which CLI runs which model with which login is the user's
		// choice; AFK doesn't police it. The limits left are technical:
		// a gateway route runs on claude only, the one CLI AFK can point
		// at a gateway with the gateway's own key, and a plan login is
		// never sent to a gateway.
		if !r.launchable(c) {
			continue
		}
		// A plan model on another vendor's CLI (OpenCode with xAI, Pi
		// with ChatGPT, ...) is reachable only when that CLI is signed in
		// to the plan. That is about what can run, not about whether it
		// should.
		if !probe.signedIn(c.Harness, c.EntitlementPool) {
			continue
		}
		if pool.State == "exhausted" || pool.State == "offline" || pool.State == "auth_required" {
			continue
		}
		if len(only) > 0 && !only[c.Harness] {
			continue
		}
		if in.OnlyPool != "" && c.EntitlementPool != in.OnlyPool {
			continue
		}
		if contains(in.ExcludePools, c.EntitlementPool) {
			continue
		}
		if in.OnlyEngineURL != "" && c.engineURL != in.OnlyEngineURL {
			continue
		}
		if c.RequiresGateway {
			gw := probe.gateway()
			if !gw.Online || !contains(gw.Models, c.Model) {
				continue
			}
		}

		var adj float64
		if pool.State == "warning" && (in.Risk == "low" || in.Risk == "medium") {
			adj -= 15
		}
		// Headroom counts only when the plan's CLI reported it. Unknown is
		// neutral (the middle), never "full".
		headroom := 50.0
		if pool.HeadroomPct != nil {
			headroom = *pool.HeadroomPct
		}
		adj += headroom * headroomWeight
		if c.BridgedOAuth {
			adj -= 0.5
		}
		if c.FrontierOnly && tc != "frontier_synthesis" && in.Risk != "critical" {
			adj -= 6
		}
		if c.SpecialistDomain == "security" {
			if tc == "security" {
				adj += 4
			} else {
				adj -= 15
			}
		}
		cross := reviewish && in.BuilderFamily != "" && c.ModelFamily != in.BuilderFamily
		if cross {
			adj += 6
		}
		if (c.RequiresGateway || c.LaunchClass == LocalLaunch) && in.Risk == "low" && (tc == "research" || tc == "coding_standard") {
			adj += 6.5
		}
		if isFree && in.Risk == "low" && (tc == "research" || tc == "coding_standard") && (in.PreferFree || subsUnderPressure) {
			adj += 14
		}
		var outRuns *int
		var outAdj *float64
		if st, ok := r.Outcomes[OutcomeKeyFor(c.Harness, c.CanonicalModel, c.Model, tc)]; ok && st.Runs() >= MinRatedRuns {
			n, a := st.Runs(), st.Adjustment()
			outRuns, outAdj = &n, &a
			adj += a
		}
		var paceAdj *float64
		if r.Pacing && pool.Pacing != nil && pool.Pacing.Adjustment != 0 {
			a := pool.Pacing.Adjustment
			paceAdj = &a
			adj += a
		}
		eff := math.Round((baseScore+adj)*100) / 100

		ef := in.resolveEffort(tc, c.Effort, c.SupportedEfforts)

		basis := bm.Basis
		if basis == "" {
			basis = "estimate"
		}
		if c.unrated {
			// Reported by the CLI, not in the catalog: there is no score
			// for it, and the default it ranks at is not shown as one.
			basis, bname, scoreText = BasisUnrated, "no benchmark", "none"
		} else if bm.Score == nil {
			basis = "estimate"
		} else if (basis == "measured" || basis == "capped") && in.Now.Unix()-bm.SyncedEpoch > in.CarrySec {
			basis = "stale"
		}
		sup := c.SupportedEfforts
		if sup == nil {
			sup = defaultEffort
		}
		source := "afk-benchmarks"
		var gwURL, engURL *string
		if c.LaunchClass == LocalLaunch {
			source = "afk-benchmarks+local"
			u := c.engineURL
			engURL = &u
		}
		if c.RequiresGateway {
			source = "afk-benchmarks+litellm"
			if in.GatewayURL != "" {
				u := in.GatewayURL
				gwURL = &u
			}
		}
		var spec *string
		if c.SpecialistDomain != "" {
			s := c.SpecialistDomain
			spec = &s
		}
		route := Route{
			Stage: in.Stage, Round: in.Round, TaskClass: tc, Risk: in.Risk,
			CandidateID: c.ID, Harness: c.Harness, LaunchClass: c.LaunchClass, Model: c.Model,
			CanonicalModel: c.CanonicalModel, ModelFamily: c.ModelFamily, SpecialistDomain: spec,
			CostClass: cclass, IsFree: isFree || cclass == "free",
			Effort: ef.effort, BaseEffort: ef.base, EffortEscalated: ef.escalated, EffortReason: ef.reason,
			SupportedEfforts: sup, WindowTokens: c.WindowTokens, EntitlementPool: c.EntitlementPool,
			PoolState:   pool.State,
			PoolUsedPct: pool.UsedPct, PoolHeadroomPct: pool.HeadroomPct, PoolQuotaSource: pool.QuotaSource, PoolUsageNote: pool.UsageNote,
			BenchmarkName: bname, BenchmarkScore: baseScore, BenchmarkBasis: basis,
			BenchmarkLive:     basis == "measured" && bm.Live,
			BenchmarkSyncedAt: bm.SyncedAt, EffectiveScore: eff, CrossFamilyReview: &cross,
			RouterSource: source, LitellmBaseURL: gwURL, AuthAlerts: alerts,
			OutcomeRuns: outRuns, OutcomeAdjustment: outAdj,
			Pacing: pool.Pacing, PacingAdjustment: paceAdj,
		}
		if engURL != nil {
			le, _ := probe.localEngineAt(*engURL)
			route.EngineURL, route.Engine, route.EngineHost, route.EngineGPU, route.EngineState = engURL, le.Engine, "this PC", probe.LocalGPU, le.State
		}
		route.Reason = reasonText(route, c, pool, ef, tc, cross, in.BuilderFamily, scoreText)
		if outAdj != nil {
			st := r.Outcomes[OutcomeKeyFor(c.Harness, c.CanonicalModel, c.Model, tc)]
			route.Reason += fmt.Sprintf(" (your ratings: %d solved, %d partly, %d wrong pick of %d; %+.1f)", st.Solved, st.Partly, st.Wrong, st.Runs(), *outAdj)
		}
		if paceAdj != nil {
			route.Reason += fmt.Sprintf(" (pacing: %s; %+.1f)", PaceText(pool.Pacing, probe.now(), time.Local), *paceAdj)
		}
		routes = append(routes, route)
	}
	sort.SliceStable(routes, func(i, j int) bool { return routes[i].EffectiveScore > routes[j].EffectiveScore })
	if len(routes) > 0 {
		return routes[0]
	}
	return r.fallback(in, tc, len(cands), alerts, probe)
}

func (r *Router) fallback(in Input, tc string, considered int, alerts []any, probe *Probe) Route {
	// In the order the probe lists them: the routable CLIs first.
	installed := []string{}
	var others []string
	for _, h := range probeOrder {
		if probe.Harnesses[h].Installed {
			installed = append(installed, h)
		}
	}
	for h, s := range probe.Harnesses {
		if h != "litellm_gateway" && s.Installed && !contains(probeOrder, h) {
			others = append(others, h)
		}
	}
	sort.Strings(others)
	installed = append(installed, others...)
	states := map[string]string{}
	for id, p := range probe.Pools {
		states[id] = p.State
	}
	var gw *string
	if in.GatewayURL != "" {
		u := in.GatewayURL
		gw = &u
	}
	return Route{
		Stage: in.Stage, Round: in.Round, TaskClass: tc, Risk: in.Risk,
		Harness: "claude", LaunchClass: "claude-native", Model: "sonnet",
		CanonicalModel: "anthropic/claude-sonnet-5-5", ModelFamily: "anthropic",
		CostClass: "subscription", Effort: "medium", BaseEffort: "medium", EffortReason: "fallback_default",
		SupportedEfforts: defaultEffort, EntitlementPool: "anthropic-max",
		// No pool figure and no score: nothing was measured or picked.
		BenchmarkName: "Fallback Default", BenchmarkBasis: "estimate",
		RouterSource: "fallback-default", NoEligibleCandidate: true, CandidatesConsidered: &considered,
		InstalledHarnesses: &installed, PoolStates: states, LitellmBaseURL: gw, AuthAlerts: alerts,
		Reason: "Fallback route (no eligible candidate matched)",
	}
}

func reasonText(rt Route, c Candidate, pool Pool, ef effortChoice, tc string, cross bool, bf, scoreText string) string {
	var sb strings.Builder
	fmt.Fprintf(&sb, "Selected %s/%s [%s, effort=%s", c.Harness, c.Model, c.CanonicalModel, ef.effort)
	if ef.escalated {
		fmt.Fprintf(&sb, " (%s)", ef.reason)
	}
	left := "usage unknown"
	if pool.HeadroomPct != nil {
		left = num(pool.HeadroomPct) + "% left"
	}
	fmt.Fprintf(&sb, ", cost=%s] (pool=%s [%s], benchmark=%s via %s",
		rt.CostClass, c.EntitlementPool, left, scoreText, rt.BenchmarkName)
	if c.SpecialistDomain == "security" && tc == "security" {
		sb.WriteString(", specialist cybersecurity model")
	}
	if cross {
		sb.WriteString(", cross-family blind review vs " + bf)
	}
	if pool.State == "warning" {
		sb.WriteString(", pool conservation penalty applied")
	}
	sb.WriteString(")")
	return sb.String()
}

func num(v *float64) string {
	if v == nil {
		return "null"
	}
	return strconv.FormatFloat(*v, 'f', -1, 64)
}

func strPtr(s string) *string {
	if s == "" {
		return nil
	}
	return &s
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}
