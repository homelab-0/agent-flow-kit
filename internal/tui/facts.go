package tui

import (
	"fmt"
	"math"
	"net/url"
	"strings"
	"time"

	"charm.land/lipgloss/v2"
	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

// Unknown values are shown as unknown, never as a zero.
const (
	unknownMeter = "[??????????]"
	unknownText  = "n/e"
)

var badgeCodes = map[string]string{
	"claude": "CL", "codex": "CX", "grok": "GK", "agy": "AG", "opencode": "OC",
	"pi": "PI", "devin": "DV", "copilot": "CP", "ollama": "OL", "vllm": "VL",
}

// badge is the 2-cell text logo of a route (step 1 draws no images).
func badge(r engine.Route) string {
	if r.IsGateway() {
		return "GW"
	}
	if c, ok := badgeCodes[r.Harness]; ok {
		return c
	}
	h := strings.ToUpper(r.Harness)
	if len(h) >= 2 {
		return h[:2]
	}
	return col(h, 2)
}

// routeName is the display id: the CLI, or "gateway" for a gateway route.
func routeName(r engine.Route) string {
	if r.IsGateway() {
		return "gateway"
	}
	return r.Harness
}

func effortText(e string) string {
	if e == "" {
		return "—"
	}
	return e
}

func scoreText(p *float64) string {
	if p == nil {
		return unknownText
	}
	if *p >= 99.95 {
		return fmt.Sprintf("%.0f", *p)
	}
	return fmt.Sprintf("%.1f", *p)
}

func pctText(p *float64) string {
	if p == nil {
		return unknownText
	}
	return fmt.Sprintf("%d%%", int(math.Round(*p)))
}

func costText(c string) string {
	switch c {
	case "subscription":
		return "plan"
	case "":
		return unknownText
	}
	return c
}

// gatewayHost is the gateway's host name; never the rest of the URL, which
// could carry user info.
func gatewayHost(r engine.Route) string {
	if r.LitellmBaseURL == "" {
		return ""
	}
	u, err := url.Parse(r.LitellmBaseURL)
	if err != nil {
		return ""
	}
	return u.Hostname()
}

// loginText says which sign-in a route uses. A plan login is only ever its
// own vendor's CLI's.
func loginText(r engine.Route) string {
	if r.IsGateway() {
		return "gateway key, no plan login · separate config dir"
	}
	switch r.Harness {
	case "claude":
		return "Claude plan login · own config dir"
	case "codex":
		return "ChatGPT plan login · codex’s own auth"
	case "grok":
		return "SuperGrok sign-in · grok’s own auth"
	case "agy":
		return "Google sign-in · agy’s own auth"
	case "opencode":
		if r.CostClass == "free" {
			return "OpenCode free tier · opencode’s own auth"
		}
	}
	pool := r.EntitlementPool
	if pool == "" {
		pool = "sign-in " + unknownText
	}
	return pool + " · " + r.Harness + "’s own auth"
}

func taskText(task string, guessed bool) string {
	if task == "" {
		task = unknownText
	}
	if guessed {
		return task + " (guessed)"
	}
	return task
}

// resetsText is when the pool's 5-hour window resets, in local time.
func resetsText(pools *engine.Pools, id string, loc *time.Location) string {
	if pools != nil {
		if p, ok := pools.Pools[id]; ok {
			if t, ok := p.Resets(); ok {
				return "resets " + t.In(loc).Format("15:04")
			}
		}
	}
	return "resets " + unknownText
}

// headroomStyle: amber below 60%, red below 20%.
func (t Theme) headroom(p *float64) styleName {
	switch {
	case p == nil:
		return stDim
	case *p < 20:
		return stBad
	case *p < 60:
		return stWarn
	}
	return stOK
}

type styleName int

const (
	stPlain styleName = iota
	stDim
	stOK
	stWarn
	stBad
)

func (t Theme) style(n styleName) lipgloss.Style {
	switch n {
	case stDim:
		return t.Dim
	case stOK:
		return t.OK
	case stWarn:
		return t.Warn
	case stBad:
		return t.Bad
	}
	return t.Plain
}

// meterCells is how many of n cells a percentage fills at progress p.
func meterCells(pct float64, n int, p float64) int {
	f := int(math.Round(pct / 100 * float64(n) * p))
	if f < 0 {
		f = 0
	}
	if f > n {
		f = n
	}
	return f
}

// meter is a 10-cell bar, or the unknown marker.
func (t Theme) meter(pct *float64, prog float64) line {
	if pct == nil {
		return line{sg(t.Dim, unknownMeter)}
	}
	f := meterCells(*pct, 10, prog)
	return line{sg(t.style(t.headroom(pct)), strings.Repeat("█", f)), sg(t.Dim, strings.Repeat("░", 10-f))}
}

func trimNum(f float64) string {
	s := fmt.Sprintf("%.1f", f)
	return strings.TrimSuffix(s, ".0")
}

func basisText(r engine.Route, now time.Time) string {
	switch r.BenchmarkBasis {
	case "measured":
		if d, ok := syncedDay(r.BenchmarkSyncedAt, now.Location()); ok {
			if d == now.Format("2006-01-02") {
				return "measured today"
			}
			return "measured " + d
		}
		return "measured"
	case "estimate":
		return "a catalog estimate"
	case "capped":
		return "capped"
	case "":
		return "basis " + unknownText
	}
	return r.BenchmarkBasis
}

func syncedDay(s string, loc *time.Location) (string, bool) {
	if s == "" {
		return "", false
	}
	for _, layout := range []string{time.RFC3339Nano, "2006-01-02"} {
		if t, err := time.Parse(layout, s); err == nil {
			return t.In(loc).Format("2006-01-02"), true
		}
	}
	return "", false
}

// reasonText is a plain-English reason for row i, from the router's fields
// only. The engine's own reason string is a log line; this says the same
// facts in words.
func reasonText(rows []engine.Route, i int, task string, now time.Time) string {
	r := rows[i]
	if r.Pinned {
		return "You picked this harness and model, so the router was not asked."
	}
	if task == "" {
		task = "this"
	}
	best, most := -1, -1
	for j, x := range rows {
		if x.EffectiveScore != nil && (best < 0 || *x.EffectiveScore > *rows[best].EffectiveScore) {
			best = j
		}
		if x.PoolHeadroomPct != nil && (most < 0 || *x.PoolHeadroomPct > *rows[most].PoolHeadroomPct) {
			most = j
		}
	}
	score := scoreText(r.EffectiveScore)
	hasMost := most >= 0 && r.PoolHeadroomPct != nil && *r.PoolHeadroomPct == *rows[most].PoolHeadroomPct
	var b strings.Builder
	switch {
	case r.EffectiveScore == nil || best < 0:
		fmt.Fprintf(&b, "The router has no %s score for this route", task)
	case best == i || *r.EffectiveScore == *rows[best].EffectiveScore:
		if len(rows) > 1 {
			fmt.Fprintf(&b, "Highest %s score among installed CLIs (%s, %s)", task, score, basisText(r, now))
		} else {
			fmt.Fprintf(&b, "Scores %s on %s (%s)", score, task, basisText(r, now))
		}
	default:
		d := trimNum(*rows[best].EffectiveScore - *r.EffectiveScore)
		if hasMost && len(rows) > 1 {
			fmt.Fprintf(&b, "Most headroom left, but %s points lower on %s than %s", d, task, routeName(rows[best]))
		} else {
			fmt.Fprintf(&b, "%s points behind %s on %s", d, routeName(rows[best]), task)
		}
		if r.BenchmarkBasis == "estimate" {
			b.WriteString(", and the score is a catalog estimate, not measured.")
			return b.String()
		}
	}
	switch {
	case r.IsGateway():
		if h := gatewayHost(r); h != "" {
			fmt.Fprintf(&b, "; free, through the gateway at %s.", h)
		} else {
			b.WriteString("; through the model gateway.")
		}
	case r.CostClass == "free":
		b.WriteString(", and free.")
	case r.PoolHeadroomPct == nil:
		b.WriteString("; its pool usage is not known.")
	case hasMost && len(rows) > 1 && (best == i):
		b.WriteString(" and the most 5-hour headroom left.")
	case hasMost:
		b.WriteString(".")
	default:
		fmt.Fprintf(&b, ", with %s of its 5-hour pool left.", pctText(r.PoolHeadroomPct))
	}
	if r.PoolHeadroomPct != nil && r.CostClass != "free" && r.PoolQuotaSource == "local_5h_activity" {
		b.WriteString(" Its pool figure is an estimate from recent sessions, not a measurement.")
	}
	return b.String()
}

// effortCycle orders a route's supported efforts from low to high.
func effortCycle(supported []string) []string {
	rank := map[string]int{"minimal": 0, "low": 1, "medium": 2, "high": 3, "xhigh": 4, "max": 5, "ultra": 6}
	out := append([]string(nil), supported...)
	for i := 1; i < len(out); i++ {
		for j := i; j > 0; j-- {
			a, aok := rank[out[j-1]]
			b, bok := rank[out[j]]
			if !aok {
				a = 99
			}
			if !bok {
				b = 99
			}
			if a <= b {
				break
			}
			out[j-1], out[j] = out[j], out[j-1]
		}
	}
	return out
}

// nextEffort is the effort after cur in the route's supported list.
func nextEffort(supported []string, cur string) string {
	c := effortCycle(supported)
	if len(c) == 0 {
		return cur
	}
	for i, e := range c {
		if e == cur {
			return c[(i+1)%len(c)]
		}
	}
	return c[0]
}

// humanize turns an identifier like benchmark_task_coding into words.
func humanize(s string) string { return strings.ReplaceAll(s, "_", " ") }

// shortModel drops the CLI's own name from the model for the compact card.
func shortModel(r engine.Route) string {
	return strings.TrimPrefix(r.Model, r.Harness+"-")
}

// duration formats a session length like 23m 41s.
func duration(d time.Duration) string {
	s := int64(d.Round(time.Second) / time.Second)
	switch {
	case s < 60:
		return fmt.Sprintf("%ds", s)
	case s < 3600:
		return fmt.Sprintf("%dm %02ds", s/60, s%60)
	}
	return fmt.Sprintf("%dh %02dm", s/3600, (s%3600)/60)
}
