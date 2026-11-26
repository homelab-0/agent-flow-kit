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
	PoolCapacity5h  *float64 `json:"pool_capacity_5h"`
	PoolRemaining5h *float64 `json:"pool_remaining_5h"`
	PoolQuotaSource string   `json:"pool_quota_source"`

	BenchmarkName     string   `json:"benchmark_name"`
	BenchmarkScore    *float64 `json:"benchmark_score"`
	BenchmarkBasis    string   `json:"benchmark_basis"`
	BenchmarkSyncedAt string   `json:"benchmark_synced_at"`
	EffectiveScore    *float64 `json:"effective_score"`

	CostClass      string   `json:"cost_class"`
	LaunchClass    string   `json:"launch_class"`
	RouterSource   string   `json:"router_source"`
	AuthAlerts     []any    `json:"auth_alerts"`
	Reason         string   `json:"reason"`
	TaskClass      string   `json:"task_class"`
	Stage          string   `json:"stage"`
	Risk           string   `json:"risk"`
	LitellmBaseURL string   `json:"litellm_base_url"`
	Pinned         bool     `json:"pinned"`
	WindowTokens   *float64 `json:"window_tokens"`
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
// (the CLI's own rate-limit record), "estimated from recent sessions", "set
// by a failed run", or "" when the route doesn't say.
func (r Route) PoolBasis() string {
	switch {
	case r.PoolQuotaSource == "codex_rate_limits":
		return "measured"
	case r.PoolQuotaSource == "local_5h_activity":
		return "estimated from recent sessions"
	case strings.HasPrefix(r.PoolQuotaSource, "runtime_signal:"):
		return "set by a failed run"
	}
	return ""
}

func (r Route) IsGateway() bool { return strings.HasSuffix(r.LaunchClass, "-gateway") }

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
	ResetsAt    string   `json:"resets_at"`
}

// Resets is when the pool's window resets, if the engine knows.
func (p Pool) Resets() (time.Time, bool) {
	if p.ResetsAt == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, p.ResetsAt)
	return t, err == nil
}

// Pools is the afk-router-pools/3 payload (the parts read here).
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
