package tui

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

func TestDurations(t *testing.T) {
	for d, want := range map[time.Duration]string{41 * time.Second: "41s", 23*time.Minute + 41*time.Second: "23m 41s", 2*time.Hour + 5*time.Minute: "2h 05m"} {
		if got := duration(d); got != want {
			t.Errorf("%v: %q, want %q", d, got, want)
		}
	}
}

func route(t *testing.T, js string) engine.Route {
	t.Helper()
	var r engine.Route
	if err := json.Unmarshal([]byte(js), &r); err != nil {
		t.Fatal(err)
	}
	return r
}

func TestEffortCycle(t *testing.T) {
	sup := []string{"high", "low", "max", "medium", "xhigh"}
	if got := strings.Join(effortCycle(sup), ","); got != "low,medium,high,xhigh,max" {
		t.Errorf("cycle %s", got)
	}
	if nextEffort(sup, "max") != "low" || nextEffort(sup, "medium") != "high" || nextEffort(nil, "high") != "high" {
		t.Error("nextEffort wraps, and keeps the effort when nothing is supported")
	}
}

func TestMeterCells(t *testing.T) {
	for _, c := range []struct {
		pct, prog float64
		want      int
	}{{78, 1, 8}, {52, 1, 5}, {91, 1, 9}, {100, 1, 10}, {0, 1, 0}, {78, 0, 0}, {150, 1, 10}} {
		if got := meterCells(c.pct, 10, c.prog); got != c.want {
			t.Errorf("meterCells(%v, %v) = %d, want %d", c.pct, c.prog, got, c.want)
		}
	}
	th := NewTheme(true)
	if got := th.meter(nil, 1).plain(); got != "[??????????]" {
		t.Errorf("an unknown headroom is the unknown marker, got %q", got)
	}
}

func TestTextHelpers(t *testing.T) {
	if got := col("claude-fable-5-2-long-name", 17); ansi.StringWidth(got) != 17 || !strings.HasSuffix(got, "…") {
		t.Errorf("col %q", got)
	}
	if got := wrap("one two three four five", 9); strings.Join(got, "|") != "one two|three|four five" {
		t.Errorf("wrap %q", got)
	}
	if scoreText(nil) != "n/e" || pctText(nil) != "n/e" || costText("subscription") != "plan" || effortText("") != "—" {
		t.Error("unknown values read n/e, never zero")
	}
}

func TestRouteFacts(t *testing.T) {
	gw := route(t, `{"harness":"claude","launch_class":"claude-gateway","litellm_base_url":"http://u:p@gw.lan:4000/v1"}`)
	if badge(gw) != "GW" || routeName(gw) != "gateway" || gatewayHost(gw) != "gw.lan" {
		t.Errorf("gateway facts: %s %s %s", badge(gw), routeName(gw), gatewayHost(gw))
	}
	cx := route(t, `{"harness":"codex","model":"gpt-6.1-sol"}`)
	if badge(cx) != "CX" || !strings.HasPrefix(loginText(cx), "ChatGPT plan login") {
		t.Errorf("codex facts: %s %s", badge(cx), loginText(cx))
	}
	if badge(route(t, `{"harness":"zed"}`)) != "ZE" {
		t.Error("an unknown CLI gets its first two letters")
	}
}

func TestReasonTextNotesAnEstimatedPool(t *testing.T) {
	now := time.Date(2026, 11, 25, 12, 0, 0, 0, time.UTC)
	note := "Its pool figure is an estimate from recent sessions, not a measurement."
	rows := []engine.Route{
		route(t, `{"harness":"codex","effective_score":90,"pool_headroom_pct":50,"benchmark_basis":"measured","cost_class":"subscription","pool_quota_source":"codex_rate_limits"}`),
		// Behind the best, with a catalog-estimate score: the score warning
		// and the pool notice both show.
		route(t, `{"harness":"claude","effective_score":80,"pool_headroom_pct":40,"benchmark_basis":"estimate","cost_class":"subscription","pool_quota_source":"local_5h_activity"}`),
		// A free route gets no pool notice.
		route(t, `{"harness":"opencode","effective_score":70,"pool_headroom_pct":30,"benchmark_basis":"estimate","cost_class":"free","pool_quota_source":"local_5h_activity"}`),
	}
	got := reasonText(rows, 1, "coding", now)
	if !strings.Contains(got, "the score is a catalog estimate, not measured.") || !strings.HasSuffix(got, note) {
		t.Errorf("estimated alternative: %q", got)
	}
	if got := reasonText(rows, 0, "coding", now); strings.Contains(got, note) {
		t.Errorf("a measured pool got the notice: %q", got)
	}
	if got := reasonText(rows, 2, "coding", now); strings.Contains(got, note) {
		t.Errorf("a free route got the notice: %q", got)
	}
}

func TestReasonText(t *testing.T) {
	now := time.Date(2026, 11, 25, 12, 0, 0, 0, time.UTC)
	rows := []engine.Route{
		route(t, `{"harness":"claude","effective_score":78.1,"pool_headroom_pct":78,"benchmark_basis":"measured","benchmark_synced_at":"2026-11-25T09:00:00Z"}`),
		route(t, `{"harness":"grok","effective_score":69.0,"pool_headroom_pct":91,"benchmark_basis":"estimate"}`),
	}
	if got := reasonText(rows, 0, "coding", now); !strings.HasPrefix(got, "Highest coding score among installed CLIs (78.1, measured today)") {
		t.Errorf("best row: %q", got)
	}
	if got := reasonText(rows, 1, "coding", now); !strings.Contains(got, "Most headroom left, but 9.1 points lower on coding than claude") {
		t.Errorf("other row: %q", got)
	}
}
