package engine

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
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
	b := []byte(`{"schema":"afk-route-explain/1","task":"coding","choice":{"harness":"codex","model":"m","effort":"high","effective_score":98.22,"window_tokens":1048576,"extra":{"k":[1,2]},"pool_headroom_pct":null},"by_harness":[]}`)
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
	ex, err := ParseExplain([]byte(`{"schema":"afk-route-explain/1","choice":{"harness":"codex","model":"gpt-test","pinned":true},"by_harness":[]}`))
	if err != nil {
		t.Fatal(err)
	}
	rows, sel := ex.Rows()
	if len(rows) != 1 || sel != 0 || rows[0].Model != "gpt-test" {
		t.Fatalf("rows %+v sel %d", rows, sel)
	}
	ex, _ = ParseExplain([]byte(`{"schema":"afk-route-explain/1","choice":{"harness":"codex","model":"b","effort":"low"},"by_harness":[{"harness":"claude","model":"a"},{"harness":"codex","model":"b","effort":"medium"}]}`))
	rows, sel = ex.Rows()
	if len(rows) != 2 || sel != 1 || rows[1].Effort != "low" {
		t.Fatalf("the choice is selected in place, with its pins: %+v %d", rows, sel)
	}
}

func TestArgs(t *testing.T) {
	got := ExplainArgs(RouteFlags{Task: "review", Harness: "codex"}, "-n flag")
	want := "agent --explain --json --task review --harness codex -- -n flag"
	if strings.Join(got, " ") != want {
		t.Errorf("explain args %q", got)
	}
	var r Route
	_ = json.Unmarshal([]byte(`{"harness":"claude","model":"m"}`), &r)
	la, stdin, err := LaunchArgs(r, "interactive", true, []string{"--continue"}, "hi")
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(la, " ") != `agent --launch-plan --json --route - --mode interactive --yolo --pass --continue -- hi` {
		t.Errorf("launch args %q", la)
	}
	if string(stdin) != `{"harness":"claude","model":"m"}` {
		t.Errorf("the route goes on stdin: %s", stdin)
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

func stub(t *testing.T, dir, name, body string) string {
	t.Helper()
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("#!/bin/sh\n"+body), 0o755); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLocateOrder(t *testing.T) {
	dir := t.TempDir()
	onPath := filepath.Join(dir, "path")
	os.Mkdir(onPath, 0o755)
	stub(t, onPath, EngineName, "exit 0\n")
	a0 := os.Args[0]
	t.Cleanup(func() { os.Args[0] = a0 })
	os.Args[0] = "afk" // invoked by name only
	next := filepath.Join(dir, "next")
	os.Mkdir(next, 0o755)
	t.Setenv("PATH", onPath)
	t.Setenv("AFK_ENGINE", "")
	if p, err := Locate(); err != nil || p != filepath.Join(onPath, EngineName) {
		t.Errorf("PATH: %q %v", p, err)
	}
	env := stub(t, dir, "my-engine", "exit 0\n")
	t.Setenv("AFK_ENGINE", env)
	if p, err := Locate(); err != nil || p != env {
		t.Errorf("AFK_ENGINE first: %q %v", p, err)
	}
	t.Setenv("AFK_ENGINE", "")
	stub(t, next, EngineName, "exit 0\n")
	os.Args[0] = filepath.Join(next, "afk")
	if p, err := Locate(); err != nil || p != filepath.Join(next, EngineName) {
		t.Errorf("next to the binary as invoked, before PATH: %q %v", p, err)
	}
	t.Setenv("AFK_ENGINE", filepath.Join(dir, "missing"))
	if _, err := Locate(); err == nil {
		t.Error("an AFK_ENGINE that is not there is an error, not a fallback")
	}
}

func TestPlanRefusalAndExit(t *testing.T) {
	dir := t.TempDir()
	e := &Engine{Path: stub(t, dir, "eng", `case "$2" in
--launch-plan) printf '{"schema":"afk-launch-plan/1","ok":false,"error":"opencode may only use opencode/ models"}'; exit 4;;
--explain) echo "afk: --prefer must be balanced, cheap or best" >&2; exit 2;;
esac
`)}
	var r Route
	_ = json.Unmarshal([]byte(`{"harness":"opencode","model":"x"}`), &r)
	_, err := e.LaunchPlan(context.Background(), r, "interactive", false, nil, "hi")
	var pe *PlanError
	if !errors.As(err, &pe) || !strings.Contains(pe.Reason, "opencode/") {
		t.Fatalf("exit 4 with ok:false is a plan refusal: %v", err)
	}
	_, err = e.Explain(context.Background(), RouteFlags{Prefer: "fastest"}, "x")
	var ee *ExitError
	if !errors.As(err, &ee) || ee.Code != 2 || !strings.Contains(ee.Error(), "--prefer") {
		t.Fatalf("an engine error keeps its exit code and message: %v", err)
	}
}

func TestRouteOnStdinAndTimeout(t *testing.T) {
	dir := t.TempDir()
	got := filepath.Join(dir, "got")
	e := &Engine{Path: stub(t, dir, "eng", `case "$2" in
--launch-plan) printf '%s' "$*" > "`+got+`.args"; cat > "`+got+`"; printf '{"schema":"afk-launch-plan/1","ok":true,"argv":["/bin/true"]}';;
--explain) (sleep 30; echo late) & echo $! > "`+got+`.pid"; sleep 30;;
esac
`)}
	var r Route
	_ = json.Unmarshal([]byte(`{"harness":"claude","litellm_base_url":"http://u:secret@gw"}`), &r)
	if _, err := e.LaunchPlan(context.Background(), r, "interactive", false, nil, "hi"); err != nil {
		t.Fatal(err)
	}
	args, _ := os.ReadFile(got + ".args")
	body, _ := os.ReadFile(got)
	if strings.Contains(string(args), "secret") || !strings.Contains(string(body), "secret") {
		t.Errorf("the route is on stdin only: args %q", args)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err := e.Explain(ctx, RouteFlags{}, "x")
	var te *TimeoutError
	if !errors.As(err, &te) || time.Since(start) > 5*time.Second {
		t.Fatalf("a hung engine and its children are stopped: %v after %v", err, time.Since(start))
	}
	raw, err := os.ReadFile(got + ".pid")
	if err != nil {
		t.Fatalf("the stub recorded its background child: %v", err)
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(raw)))
	if err != nil || pid <= 0 {
		t.Fatalf("background pid %q: %v", raw, err)
	}
	t.Cleanup(func() { killPid(pid) })
	deadline := time.Now().Add(3 * time.Second)
	for processAlive(pid) {
		if time.Now().After(deadline) {
			t.Fatalf("background child %d outlived the timeout", pid)
		}
		time.Sleep(50 * time.Millisecond)
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
	_, stdin, err := LaunchArgs(r, "interactive", false, nil, "hi")
	if err != nil || string(stdin) == "null" || !strings.Contains(string(stdin), `"harness":"claude"`) {
		t.Errorf("a typed route goes to the engine whole, not as null: %s %v", stdin, err)
	}
}

func TestLocateRelativeOverride(t *testing.T) {
	dir := t.TempDir()
	stub(t, dir, "my-engine", "exit 0\n")
	wd, _ := os.Getwd()
	t.Cleanup(func() { os.Chdir(wd) })
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Setenv("AFK_ENGINE", "my-engine")
	p, err := Locate()
	if err != nil || p != filepath.Join(dir, "my-engine") {
		t.Errorf("a relative AFK_ENGINE comes back as the absolute path it checked: %q %v", p, err)
	}
}

func TestCallTimeoutCeiling(t *testing.T) {
	dir := t.TempDir()
	e := &Engine{Path: stub(t, dir, "eng", "sleep 30\n")}
	old := CallTimeout
	CallTimeout = 300 * time.Millisecond
	t.Cleanup(func() { CallTimeout = old })
	start := time.Now()
	_, err := e.Explain(context.Background(), RouteFlags{}, "x")
	var te *TimeoutError
	if !errors.As(err, &te) || time.Since(start) > 5*time.Second {
		t.Fatalf("a call with no deadline still stops: %v after %v", err, time.Since(start))
	}
}

func TestParseExplainAcceptsBothVersions(t *testing.T) {
	for _, s := range []string{SchemaExplain, SchemaExplainV1} {
		if _, err := ParseExplain([]byte(`{"schema":"` + s + `","choice":{"harness":"claude"}}`)); err != nil {
			t.Errorf("%s: %v", s, err)
		}
	}
	if _, err := ParseExplain([]byte(`{"schema":"afk-route-explain/9","choice":{"harness":"claude"}}`)); err == nil {
		t.Error("an unknown version was accepted")
	}
}
