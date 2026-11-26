package engine

import (
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func TestSchemaRefused(t *testing.T) {
	for _, b := range []string{`{"schema":"afk-route-explain/3","choice":{"harness":"claude"}}`, `{"choice":{"harness":"claude"}}`} {
		_, err := ParseExplain([]byte(b))
		var se *SchemaError
		if !errors.As(err, &se) {
			t.Errorf("%s: want a schema error, got %v", b, err)
		}
	}
	if _, err := ParseLaunchPlan([]byte(`{"schema":"afk-launch-plan/9","ok":true,"argv":["x"]}`)); err == nil {
		t.Error("an unknown launch plan schema is refused")
	}
	if _, err := ParsePools([]byte(`{"schema":"afk-router-pools/2"}`)); err == nil {
		t.Error("an unknown pools schema is refused")
	}
}

func TestRouteKeepsWholeObject(t *testing.T) {
	b := []byte(`{"schema":"afk-route-explain/2","task":"coding","choice":{"harness":"codex","model":"m","effort":"high","effective_score":98.22,"window_tokens":1048576,"extra":{"k":[1,2]},"pool_headroom_pct":null},"by_harness":[]}`)
	ex, err := ParseExplain(b)
	if err != nil {
		t.Fatal(err)
	}
	r := ex.Choice
	if r.PoolHeadroomPct != nil || r.EffectiveScore == nil || *r.EffectiveScore != 98.22 {
		t.Fatalf("typed fields: %+v", r)
	}
	r2 := r.WithEffort("xhigh")
	out, _ := json.Marshal(r2)
	for _, want := range []string{`"effort":"xhigh"`, `"effective_score":98.22`, `"window_tokens":1048576`, `"extra":{"k":[1,2]}`} {
		if !strings.Contains(string(out), want) {
			t.Errorf("round trip lacks %s: %s", want, out)
		}
	}
	if r.Effort != "high" || r.Raw["effort"] != "high" {
		t.Error("WithEffort leaves the original alone")
	}
}

func TestRowsIncludePinnedChoice(t *testing.T) {
	ex, err := ParseExplain([]byte(`{"schema":"afk-route-explain/2","choice":{"harness":"codex","model":"gpt-test","pinned":true},"by_harness":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	rows, sel := ex.Rows()
	if len(rows) != 1 || sel != 0 || rows[0].Model != "gpt-test" {
		t.Fatalf("rows %+v sel %d", rows, sel)
	}
	ex, _ = ParseExplain([]byte(`{"schema":"afk-route-explain/2","choice":{"harness":"codex","model":"b","effort":"low"},"by_harness":[{"harness":"claude","model":"a"},{"harness":"codex","model":"b","effort":"medium"}]}`))
	rows, sel = ex.Rows()
	if len(rows) != 2 || sel != 1 || rows[1].Effort != "low" {
		t.Fatalf("the choice is selected in place, with its pins: %+v %d", rows, sel)
	}
}

func TestRedacted(t *testing.T) {
	var r Route
	_ = json.Unmarshal([]byte(`{"harness":"claude","litellm_base_url":"http://user:pw@gw.lan:4000/v1"}`), &r)
	out, _ := json.Marshal(r.Redacted())
	if strings.Contains(string(out), "pw") || strings.Contains(string(out), "user") || !strings.Contains(string(out), `"litellm_base_url":"http://gw.lan:4000/v1"`) {
		t.Errorf("redacted %s", out)
	}
	if !strings.Contains(r.LitellmBaseURL, "pw@") {
		t.Error("Redacted leaves the original alone")
	}
}

func TestTypedOnlyRoutes(t *testing.T) {
	r := Route{Harness: "claude", Model: "m", LitellmBaseURL: "http://u:pw@gw/v1"}
	for name, got := range map[string]Route{"effort": r.WithEffort("high"), "redacted": r.Redacted(), "both": r.Redacted().WithEffort("low")} {
		out, err := json.Marshal(got)
		if err != nil || !strings.Contains(string(out), `"harness":"claude"`) || !strings.Contains(string(out), `"model":"m"`) {
			t.Errorf("%s: a route built in code keeps its identity: %s %v", name, out, err)
		}
		if name != "effort" && strings.Contains(string(out), "pw") {
			t.Errorf("%s: user info stays out: %s", name, out)
		}
	}
	if e := r.WithEffort("high"); e.Effort != "high" || e.Raw != nil {
		t.Errorf("WithEffort on a typed route: %+v", e)
	}
}

func TestParseExplainRefusesVersion1(t *testing.T) {
	if _, err := ParseExplain([]byte(`{"schema":"` + SchemaExplain + `","choice":{"harness":"claude"}}`)); err != nil {
		t.Errorf("%s: %v", SchemaExplain, err)
	}
	// Version 1 was only ever written by the bash engine, which is gone.
	for _, v := range []string{"afk-route-explain/1", "afk-route-explain/9"} {
		if _, err := ParseExplain([]byte(`{"schema":"` + v + `","choice":{"harness":"claude"}}`)); err == nil {
			t.Errorf("%s was accepted", v)
		}
	}
}

func TestWindowIsTheFullerOne(t *testing.T) {
	f := func(v float64) *float64 { return &v }
	for _, c := range []struct {
		five, week *float64
		want       string
	}{
		{nil, nil, "5h"},
		{f(10), nil, "5h"},
		{nil, f(10), "weekly"},
		{f(10), f(60), "weekly"},
		{f(70), f(60), "5h"},
	} {
		if got := (Pool{FiveHourUsedPct: c.five, WeeklyUsedPct: c.week}).Window(); got != c.want {
			t.Errorf("5h %v weekly %v: %s, want %s", c.five, c.week, got, c.want)
		}
	}
}
