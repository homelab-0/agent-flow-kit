package router

import (
	"math"
	"time"

	"github.com/homelab-0/agent-flow-kit/internal/harness"
)

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
	// LimitWindows are the kinds of limit the plan's CLI listed in its
	// account report: "5h", "weekly", "other". A kind that is missing is
	// a limit the plan doesn't have, as far as the CLI says. Absent when
	// the figure isn't from a full report (a run's rate-limit event names
	// one window only), and then nothing is known about the others.
	LimitWindows []string `json:"limit_windows,omitempty"`
	// Extra is usage the plan allows beyond its windows (credits,
	// overage), as the plan's own CLI reported it; nil when it said
	// nothing.
	Extra *harness.Extra `json:"extra,omitempty"`
	// UsageNote says why there is no usage figure, in the CLI's terms,
	// when there is none.
	UsageNote string `json:"usage_note,omitempty"`
	// Pacing is where the window is heading at the rate so far, when the
	// figures are measured.
	Pacing *Pacing `json:"pacing,omitempty"`
	// ObservedAt is when the CLI reported the figure, when it is a
	// reported one: a reading can be hours old, and is shown as such.
	ObservedAt *string `json:"observed_at,omitempty"`
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
	// Online is for the gateway only.
	Online bool `json:"online,omitempty"`
	// Models are the models the gateway serves or the CLI reported for
	// this account. For a CLI, ModelsKnown says whether it reported a
	// list at all; without one, AFK knows nothing about its models.
	Models       []string `json:"models,omitempty"`
	ModelsKnown  bool     `json:"models_known,omitempty"`
	DefaultModel string   `json:"default_model,omitempty"`
	// Plan, Windows, Extra and UsageNote are the CLI's own account
	// report (see harness.Account).
	Plan      string           `json:"plan,omitempty"`
	Windows   []harness.Window `json:"usage_windows,omitempty"`
	Extra     *harness.Extra   `json:"extra,omitempty"`
	UsageNote string           `json:"usage_note,omitempty"`
	// UsageSource is harness.SourceVendor when the figures came from
	// the vendor's usage service (an opt-in), "" from the CLI.
	UsageSource string `json:"usage_source,omitempty"`
	// AskedAt is when the CLI reported it (unix seconds).
	AskedAt int64 `json:"asked_at,omitempty"`
}

// account copies a CLI's account report into its state.
func (st *HarnessState) account(a harness.Account) {
	st.Models, st.ModelsKnown, st.DefaultModel = a.Models, a.ModelsKnown, a.DefaultModel
	st.Plan, st.Windows, st.Extra, st.UsageNote, st.AskedAt = a.Plan, a.Windows, a.Extra, a.UsageNote, a.At
	st.UsageSource = a.UsageSource
}

// accountQuota turns the usage windows a CLI reported into a reading:
// the fullest unexpired window is the figure, and its reset and name go
// with it.
func accountQuota(st HarnessState, source string, now int64) (quota, bool) {
	q := quota{Source: source, FetchedEpochRaw: st.AskedAt}
	fullest := -1.0
	for _, w := range st.Windows {
		kind := "other"
		switch w.Minutes {
		case 300:
			kind = "5h"
		case 10080:
			kind = "weekly"
		}
		if !contains(q.Limits, kind) {
			q.Limits = append(q.Limits, kind)
		}
		if w.ResetsAt != 0 && w.ResetsAt <= now {
			continue
		}
		used := math.Max(0, math.Min(100, math.Round(w.UsedPct)))
		// Only a window of that exact length is the 5-hour or the weekly
		// figure; another length still counts for the pool's main figure.
		// A plan split into groups (Antigravity) has one of each per group:
		// the fullest is the figure.
		if w.Minutes == 300 && (q.FiveHourPct == nil || used > *q.FiveHourPct) {
			q.FiveHourPct = f64(used)
		}
		if w.Minutes == 10080 && (q.SevenDayPct == nil || used > *q.SevenDayPct) {
			q.SevenDayPct = f64(used)
		}
		if w.UsedPct <= fullest {
			continue
		}
		fullest = w.UsedPct
		q.OK, q.UsedPct, q.ResetsAtEpoch = true, used, nil
		if w.ResetsAt != 0 {
			q.ResetsAtEpoch = f64(float64(w.ResetsAt))
		}
		switch {
		case w.Minutes == 300:
			q.Window = "5h"
		case w.Minutes == 10080:
			q.Window = "weekly"
		case w.Minutes > 0:
			q.Window = "other"
		default:
			q.Window = ""
		}
	}
	if q.OK && st.Plan != "" {
		p := st.Plan
		q.PlanType = &p
	}
	return q, q.OK
}

// vendorQuota is accountQuota for figures that came from the vendor's
// usage service; a CLI's own figures are not taken here.
func vendorQuota(st HarnessState, now int64) (quota, bool) {
	if st.UsageSource != harness.SourceVendor {
		return quota{}, false
	}
	return accountQuota(st, SourceVendor, now)
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
