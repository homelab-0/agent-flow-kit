package router

import "time"

// PoolsSchema is the version of the pool probe document.
const PoolsSchema = "afk-router-pools/5"

// Pool is how much is left in one subscription pool.
type Pool struct {
	PoolID   string `json:"pool_id,omitempty"`
	Provider string `json:"provider,omitempty"`
	// Plan is the plan name the CLI itself reported with its usage
	// reading (Codex does); empty when it reported none. Never guessed.
	Plan      string `json:"plan,omitempty"`
	CostClass string `json:"cost_class,omitempty"`
	State     string `json:"state"`
	// UsedPct and HeadroomPct are set only from a reading the plan's own
	// CLI reported; null means AFK doesn't know (see QuotaSource).
	UsedPct            *float64 `json:"used_pct"`
	HeadroomPct        *float64 `json:"headroom_pct"`
	QuotaSource        string   `json:"quota_source,omitempty"`
	WeeklyUsedPct      *float64 `json:"weekly_used_pct,omitempty"`
	FiveHourUsedPct    *float64 `json:"five_hour_used_pct,omitempty"`
	FableWeeklyUsedPct *float64 `json:"fable_weekly_used_pct,omitempty"`
	ResetsAt           *string  `json:"resets_at,omitempty"`
	// Window is the window the figure and reset are for ("5h", "weekly"),
	// when the reading names it.
	Window string `json:"window,omitempty"`
	// Pacing is where the window is heading at the rate so far, when the
	// figures are measured.
	Pacing *Pacing `json:"pacing,omitempty"`
	// observed is when the measured reading was taken.
	observed time.Time
	// SetAside says a failed run, not a usage reading, is why this pool
	// isn't used; SetAsideUntil is when that ends by itself (absent: it
	// holds until cleared with afk pools clear).
	SetAside       bool    `json:"set_aside,omitempty"`
	SetAsideUntil  *string `json:"set_aside_until,omitempty"`
	DegradedKind   *string `json:"degraded_kind,omitempty"`
	DegradedReason *string `json:"degraded_reason,omitempty"`
}

// HarnessState is whether a CLI is installed, as the probe saw it.
type HarnessState struct {
	Installed bool `json:"installed"`
	// Gateway only.
	Online bool     `json:"online,omitempty"`
	Models []string `json:"models,omitempty"`
}

// Probe is the state of every pool and CLI at routing time.
type Probe struct {
	Schema            string                  `json:"schema"`
	Harnesses         map[string]HarnessState `json:"harnesses"`
	AuthAlerts        []any                   `json:"auth_alerts"`
	UnavailableModels map[string]any          `json:"unavailable_models"`
	Pools             map[string]Pool         `json:"pools"`
	ProbeFailed       bool                    `json:"probe_failed,omitempty"`
	// Bindings lists, per pool, the CLIs signed in to it. Nil means
	// unknown, and then no candidate is held back for want of a login.
	Bindings map[string][]string `json:"bindings,omitempty"`
	// Local are the inference engines found on this machine, and LocalGPU
	// its GPU ("" when it can't tell).
	Local    []LocalEngine `json:"local,omitempty"`
	LocalGPU string        `json:"local_gpu,omitempty"`
	at       time.Time     // when the probe ran
}

// gateway is the probe's entry for the model gateway.
func (p *Probe) gateway() HarnessState { return p.Harnesses["litellm_gateway"] }

func f64(v float64) *float64 { return &v }

// defaultPool is used for a pool the probe does not know.
func defaultPool(costClass string) Pool {
	if costClass == "" {
		costClass = "subscription"
	}
	return Pool{State: "available", CostClass: costClass, QuotaSource: SourceUnknown}
}

// now is when the probe ran (the clock, for a probe built by hand).
func (p *Probe) now() time.Time {
	if p.at.IsZero() {
		return time.Now()
	}
	return p.at
}
