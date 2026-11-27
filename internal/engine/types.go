package engine

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"
	"time"
)

// Route is one routing decision: the router's JSON object, kept whole so it
// goes back to the engine unchanged, plus the fields the front end reads.
// Pointer fields are nil when the engine did not say: the screen shows them
// as unknown, never as zero.
type Route struct {
	Raw map[string]any `json:"-"`

	Harness          string   `json:"harness"`
	Model            string   `json:"model"`
	CanonicalModel   string   `json:"canonical_model"`
	Effort           string   `json:"effort"`
	BaseEffort       string   `json:"base_effort"`
	EffortEscalated  bool     `json:"effort_escalated"`
	EffortReason     string   `json:"effort_reason"`
	SupportedEfforts []string `json:"supported_efforts"`

	EntitlementPool string   `json:"entitlement_pool"`
	PoolState       string   `json:"pool_state"`
	PoolHeadroomPct *float64 `json:"pool_headroom_pct"`
	PoolUsedPct     *float64 `json:"pool_used_pct"`
	PoolQuotaSource string   `json:"pool_quota_source"`

	BenchmarkName     string   `json:"benchmark_name"`
	BenchmarkScore    *float64 `json:"benchmark_score"`
	BenchmarkBasis    string   `json:"benchmark_basis"`
	BenchmarkSyncedAt string   `json:"benchmark_synced_at"`
	EffectiveScore    *float64 `json:"effective_score"`

	CostClass      string `json:"cost_class"`
	LaunchClass    string `json:"launch_class"`
	RouterSource   string `json:"router_source"`
	AuthAlerts     []any  `json:"auth_alerts"`
	Reason         string `json:"reason"`
	TaskClass      string `json:"task_class"`
	Stage          string `json:"stage"`
	Risk           string `json:"risk"`
	LitellmBaseURL string `json:"litellm_base_url"`
	GatewayName    string `json:"gateway_name"`
	GatewayKind    string `json:"gateway_kind"`
	Engine         string `json:"engine"`
	EngineHost     string `json:"engine_host"`
	// A local model's engine address, this machine's GPU, and whether the
	// engine has a model loaded ("idle", "loaded"; "" unknown).
	EngineURL    string   `json:"engine_url"`
	EngineGPU    string   `json:"engine_gpu"`
	EngineState  string   `json:"engine_state"`
	Pinned       bool     `json:"pinned"`
	WindowTokens *float64 `json:"window_tokens"`
	// Pacing is the route's pool projection; PacingAdjustment is what it
	// moved the score, nil when route.pacing is off or it moved nothing.
	Pacing           *Pacing  `json:"pacing"`
	PacingAdjustment *float64 `json:"pacing_adjustment"`
}

// UnmarshalJSON keeps the whole object and reads the typed fields from it.
func (r *Route) UnmarshalJSON(b []byte) error {
	type plain Route
	var p plain
	if err := json.Unmarshal(b, &p); err != nil {
		return err
	}
	dec := json.NewDecoder(bytes.NewReader(b))
	dec.UseNumber()
	var raw map[string]any
	if err := dec.Decode(&raw); err != nil {
		return err
	}
	*r = Route(p)
	r.Raw = raw
	return nil
}

// MarshalJSON writes the whole object, with any changes made through With.
func (r Route) MarshalJSON() ([]byte, error) {
	if r.Raw == nil {
		type plain Route
		return json.Marshal(plain(r))
	}
	return json.Marshal(r.Raw)
}

// WithEffort returns a copy of the route with another effort.
func (r Route) WithEffort(effort string) Route {
	r.Effort = effort
	if r.Raw == nil {
		// A route built in code has only its typed fields; MarshalJSON
		// writes those.
		return r
	}
	raw := make(map[string]any, len(r.Raw)+1)
	for k, v := range r.Raw {
		raw[k] = v
	}
	if effort == "" {
		raw["effort"] = nil
	} else {
		raw["effort"] = effort
	}
	r.Raw = raw
	return r
}

// Redacted is the route as it may be stored: the gateway address keeps its
// host and path but loses any user info and query.
func (r Route) Redacted() Route {
	if r.LitellmBaseURL == "" {
		return r
	}
	clean := redactURL(r.LitellmBaseURL)
	if r.Raw == nil {
		r.LitellmBaseURL = clean
		return r
	}
	raw := make(map[string]any, len(r.Raw))
	for k, v := range r.Raw {
		raw[k] = v
	}
	raw["litellm_base_url"] = clean
	r.Raw, r.LitellmBaseURL = raw, clean
	return r
}

func redactURL(s string) string {
	u, err := url.Parse(s)
	if err != nil {
		return ""
	}
	// User info is a credential, and so may a query be (?api_key=...).
	u.User, u.RawQuery, u.Fragment = nil, "", ""
	return u.String()
}

// IsGateway reports a route that goes through a model gateway.
// PoolBasis says how the pool figures were found, for people: "measured"
// (the CLI's own rate-limit record), "measured at the last afk -p run"
// (Claude's, read from a one-shot run's output), "set by a failed run",
// "not signed in", or "" when nothing reported the pool's usage.
func (r Route) PoolBasis() string {
	switch {
	case r.PoolQuotaSource == "codex_rate_limits":
		return "measured"
	case r.PoolQuotaSource == "claude_rate_limit_event":
		return "measured at the last afk -p run"
	case r.PoolQuotaSource == "unauthenticated":
		return "not signed in"
	case strings.HasPrefix(r.PoolQuotaSource, "runtime_signal:"):
		return "set by a failed run"
	}
	return ""
}

func (r Route) IsGateway() bool { return strings.HasSuffix(r.LaunchClass, "-gateway") }

// IsLocal reports a route to a model running on this machine.
func (r Route) IsLocal() bool { return r.LaunchClass == "claude-local" }

// SameAs reports whether two routes start the same thing.
func (r Route) SameAs(o Route) bool {
	return r.Harness == o.Harness && r.Model == o.Model && r.LaunchClass == o.LaunchClass
}

// Explain is the afk-route-explain/2 payload.
type Explain struct {
	Schema      string  `json:"schema"`
	Task        string  `json:"task"`
	TaskGuessed bool    `json:"task_guessed"`
	Prefer      string  `json:"prefer"`
	Choice      Route   `json:"choice"`
	ByHarness   []Route `json:"by_harness"`
	// Mode is the permission mode asked for and where it came from;
	// ModeByHarness is what each CLI runs it as (stricter when it can't
	// do it, with a note).
	Mode          string              `json:"mode,omitempty"`
	ModeSource    string              `json:"mode_source,omitempty"`
	ModeByHarness map[string]ModeInfo `json:"mode_by_harness,omitempty"`
}

// ModeInfo is the permission mode a CLI runs in.
type ModeInfo struct {
	Mode string `json:"mode"`
	Note string `json:"note,omitempty"`
}

// ParseExplain reads and checks an explain payload.
func ParseExplain(b []byte) (*Explain, error) {
	if err := checkSchema(b, SchemaExplain); err != nil {
		return nil, err
	}
	var e Explain
	if err := json.Unmarshal(b, &e); err != nil {
		return nil, fmt.Errorf("cannot read the routing decision: %w", err)
	}
	if e.Choice.Harness == "" {
		return nil, fmt.Errorf("the routing decision names no harness")
	}
	return &e, nil
}

// Rows is the table the route card shows: the best route per CLI, best
// first, with the router's choice in it even when it was pinned.
func (e *Explain) Rows() (rows []Route, choice int) {
	rows = append(rows, e.ByHarness...)
	for i, r := range rows {
		if r.SameAs(e.Choice) {
			// The choice carries the user's pins (effort); show those.
			rows[i] = e.Choice
			return rows, i
		}
	}
	return append([]Route{e.Choice}, rows...), 0
}

// LaunchPlan is the afk-launch-plan/1 payload.
type LaunchPlan struct {
	Schema   string            `json:"schema"`
	OK       bool              `json:"ok"`
	Error    string            `json:"error"`
	Argv     []string          `json:"argv"`
	EnvSet   map[string]string `json:"env_set"`
	EnvFrom  map[string]string `json:"env_from"`
	EnvUnset []string          `json:"env_unset"`
	Cwd      string            `json:"cwd"`
	Answer   json.RawMessage   `json:"answer"`
	// Mode is the permission mode the CLI runs in, and ModeNote says why
	// when it is stricter than the one asked for.
	Mode     string `json:"mode,omitempty"`
	ModeNote string `json:"mode_note,omitempty"`
	// ConfigNote says what a one-shot run outside a trusted repository
	// does about the settings that directory carries.
	ConfigNote string `json:"config_note,omitempty"`
}

// ParseLaunchPlan reads and checks a launch plan.
func ParseLaunchPlan(b []byte) (*LaunchPlan, error) {
	if err := checkSchema(b, SchemaLaunchPlan); err != nil {
		return nil, err
	}
	var p LaunchPlan
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, fmt.Errorf("cannot read the launch plan: %w", err)
	}
	if p.OK && len(p.Argv) == 0 {
		return nil, fmt.Errorf("the launch plan has no command")
	}
	return &p, nil
}

// Pool is one plan pool's usage.
type Pool struct {
	PoolID      string   `json:"pool_id"`
	Provider    string   `json:"provider"`
	CostClass   string   `json:"cost_class"`
	State       string   `json:"state"`
	HeadroomPct *float64 `json:"headroom_pct"`
	UsedPct     *float64 `json:"used_pct"`
	// QuotaSource is where the figures came from; "unknown" and
	// "unauthenticated" carry none.
	QuotaSource string `json:"quota_source"`
	ResetsAt    string `json:"resets_at"`
	// The plan's own windows, when the CLI reports them.
	FiveHourUsedPct *float64 `json:"five_hour_used_pct"`
	WeeklyUsedPct   *float64 `json:"weekly_used_pct"`
	// UsageWindow is the window the figure and reset are for, as the
	// reading named it ("5h", "weekly"); "" when it didn't.
	UsageWindow string `json:"window"`
	// Pacing is where a measured window is heading, when projected.
	Pacing *Pacing `json:"pacing"`
	// ObservedAt is when the CLI reported the figure (RFC 3339); "" when
	// there is no reported figure.
	ObservedAt string `json:"observed_at"`
}

// StaleReading is how old a reported figure gets before its age is shown
// beside it.
const StaleReading = 15 * time.Minute

// ReadAgo is how long ago the pool's figure was reported, when it is old
// enough to say so: "3h ago", "25m ago". "" for a fresh reading or none.
func (p Pool) ReadAgo(now time.Time) string {
	return ReadAgo(p.ObservedAt, now)
}

// ReadAgo is Pool.ReadAgo for a bare observed_at value.
func ReadAgo(observedAt string, now time.Time) string {
	if observedAt == "" {
		return ""
	}
	t, err := time.Parse(time.RFC3339, observedAt)
	if err != nil {
		return ""
	}
	d := now.Sub(t)
	switch {
	case d < StaleReading:
		return ""
	case d < time.Hour:
		return fmt.Sprintf("%dm ago", int(d/time.Minute))
	case d < 48*time.Hour:
		return fmt.Sprintf("%dh ago", int(d/time.Hour))
	}
	return fmt.Sprintf("%dd ago", int(d/(24*time.Hour)))
}

// Window names the window a pool's figure is for: the one the reading
// named, else "weekly" when the weekly reading is the fuller one (or the
// only one), else "5h".
func (p Pool) Window() string {
	if p.UsageWindow == "5h" || p.UsageWindow == "weekly" {
		return p.UsageWindow
	}
	// The figure shown is the fuller window's, so name that one.
	switch {
	case p.WeeklyUsedPct == nil:
		return "5h"
	case p.FiveHourUsedPct == nil || *p.WeeklyUsedPct > *p.FiveHourUsedPct:
		return "weekly"
	}
	return "5h"
}

// Resets is when the pool's window resets, if the engine knows.
func (p Pool) Resets() (time.Time, bool) {
	if p.ResetsAt == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, p.ResetsAt)
	return t, err == nil
}

// Pools is the afk-router-pools/4 payload (the parts read here).
type Pools struct {
	Schema string          `json:"schema"`
	Pools  map[string]Pool `json:"pools"`
}

// ParsePools reads and checks a pools payload.
func ParsePools(b []byte) (*Pools, error) {
	if err := checkSchema(b, SchemaPools); err != nil {
		return nil, err
	}
	var p Pools
	if err := json.Unmarshal(b, &p); err != nil {
		return nil, fmt.Errorf("cannot read pool usage: %w", err)
	}
	return &p, nil
}

// Headroom is a pool's headroom in percent, if known.
func (p *Pools) Headroom(id string) *float64 {
	if p == nil || id == "" {
		return nil
	}
	if pl, ok := p.Pools[id]; ok {
		return pl.HeadroomPct
	}
	return nil
}
