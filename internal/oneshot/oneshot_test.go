package oneshot

import (
	"context"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

// The fixtures in testdata are what each CLI prints in JSON mode, for an
// answer and for the failures afk -p reacts to. Nothing here starts a CLI.
func fixture(t *testing.T, name string) []byte {
	t.Helper()
	b, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestAnswer(t *testing.T) {
	cases := []struct {
		name, stdout, answer string
		want                 string
		ok                   bool
	}{
		{"claude answer", "claude-ok.json", "", "The answer is 42.\n", true},
		{"claude reports a spent plan with is_error", "claude-usage-limit.json", "", "Claude AI usage limit reached|1764200000", false},
		{"codex answer comes from its answer file", "codex-ok.jsonl", "codex-answer.txt", "Codex says hello.\n", true},
		{"codex turn.failed", "codex-failed.jsonl", "", "stream disconnected before completion", false},
		{"opencode joins its text parts", "opencode-ok.jsonl", "", "Hello, world.", true},
		{"error.data.message", "opencode-auth.jsonl", "", "401 Unauthorized: please log in", false},
		{"an error given as a string", "grok-rate-limit.json", "", "429 Too Many Requests", false},
		{"output that is not JSON is the answer", "plain.txt", "", "plain words, not JSON\n", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var ans []byte
			if tc.answer != "" {
				ans = fixture(t, tc.answer)
			}
			got, ok := Answer(fixture(t, tc.stdout), ans)
			if got != tc.want || ok != tc.ok {
				t.Errorf("got %q %v, want %q %v", got, ok, tc.want, tc.ok)
			}
		})
	}
	// A status line before the error is not the reason.
	got, ok := Answer([]byte(`{"type":"status","message":"connected"}`+"\n"+`{"type":"error","error":{"message":"401 Unauthorized"}}`), nil)
	if ok || got != "401 Unauthorized" || Classify(got) != KindPool {
		t.Errorf("status line then error: %q %v", got, ok)
	}
	if got, ok := Answer([]byte(`{"type":"error"}`), nil); ok || got != "the CLI reported an error" {
		t.Errorf("an error with no message: %q %v", got, ok)
	}
}

func TestClassify(t *testing.T) {
	for text, want := range map[string]Kind{
		"Claude AI usage limit reached":               KindPool,
		"401 Unauthorized":                            KindPool,
		"Error: not logged in":                        KindPool,
		"rate_limit_error":                            KindPool,
		"Your credit balance is too low":              KindPool,
		"529 overloaded":                              KindPool,
		"model_not_found: gpt-old":                    KindModel,
		"your org does not have access to this model": KindModel,
		"Unknown model 'x'":                           KindModel,
		"stream disconnected before completion":       KindOther,
		"exception at worker.go line 1401":            KindOther,
		"QuotaManager failed to start":                KindOther,
		"cannot launch grok / grok-4 here: no CLI":    KindOther,
	} {
		if got := Classify(text); got != want {
			t.Errorf("%q: %s, want %s", text, got, want)
		}
	}
	if got := PoolReason("Claude AI usage limit reached"); got != "quota: Claude AI usage limit reached" {
		t.Errorf("usage limit reason: %q", got)
	}
	if got := PoolReason("429 rate limit"); got != "429 rate limit" {
		t.Errorf("a reason the router already reads as quota: %q", got)
	}
}

// fake is a scripted run: the output for each harness/model, in turn, and
// the routes the router answers with.
type fake struct {
	outputs map[string][]Output
	next    []engine.Route
	ran     []string
	asked   [][]string
	marks   []string
	notes   []string
}

func (f *fake) deps() Deps {
	return Deps{
		Run: func(_ context.Context, r engine.Route, _ string) Output {
			id := r.Harness + "/" + r.Model
			f.ran = append(f.ran, id+"@"+r.Effort)
			outs := f.outputs[id]
			if len(outs) == 0 {
				return Output{Exit: 1, Stderr: []byte("no output scripted for " + id)}
			}
			o := outs[0]
			f.outputs[id] = outs[1:]
			return o
		},
		Next: func(_ context.Context, only []string, pool string) (engine.Route, bool) {
			f.asked = append(f.asked, append([]string(nil), only...))
			for i, r := range f.next {
				for _, h := range only {
					if r.Harness == h && (pool == "" || r.EntitlementPool == pool) {
						f.next = append(f.next[:i], f.next[i+1:]...)
						return r, true
					}
				}
			}
			return engine.Route{}, false
		},
		Mark: func(kind Kind, pool, model, reason string) {
			f.marks = append(f.marks, string(kind)+" "+pool+" "+model+" "+reason)
		},
		Note: func(s string) { f.notes = append(f.notes, s) },
	}
}

func route(h, m, pool string) engine.Route {
	return engine.Route{Harness: h, Model: m, EntitlementPool: pool}
}

var all = []string{"claude", "codex", "opencode", "grok"}

func TestFailoverOrder(t *testing.T) {
	f := &fake{
		outputs: map[string][]Output{
			// A spent plan reported with exit 0: still a failure.
			"claude/opus":         {{Stdout: fixture(t, "claude-usage-limit.json"), Exit: 0}},
			"codex/sol":           {{Stdout: fixture(t, "codex-failed.jsonl"), Exit: 1}},
			"opencode/big-pickle": {{Stdout: fixture(t, "opencode-ok.jsonl")}},
		},
		next: []engine.Route{route("codex", "sol", "openai-plus"), route("opencode", "big-pickle", "opencode-free")},
	}
	res := Do(context.Background(), Request{First: route("claude", "opus", "anthropic-max"), Harnesses: all, Effort: "high"}, f.deps())
	if !res.OK || res.Output != "Hello, world." || res.Attempts != 3 || res.Route.Harness != "opencode" {
		t.Fatalf("result %+v", res)
	}
	want(t, "tried in order", res.Tried, []string{"claude/opus", "codex/sol", "opencode/big-pickle"})
	// --effort applies to every route the run moves to.
	want(t, "ran", f.ran, []string{"claude/opus@", "codex/sol@high", "opencode/big-pickle@high"})
	// A pool failure leaves every CLI allowed (the router sets the pool
	// aside); any other failure keeps the run away from that CLI.
	want(t, "asked", f.asked, [][]string{all, {"claude", "opencode", "grok"}})
	want(t, "marks", f.marks, []string{"pool anthropic-max opus quota: Claude AI usage limit reached|1764200000"})
	want(t, "notes", f.notes, []string{
		"afk: claude/opus failed (pool); trying codex / sol",
		"afk: codex/sol failed (other); trying opencode / big-pickle",
	})
}

func TestModelFailureSetsTheModelAside(t *testing.T) {
	f := &fake{
		outputs: map[string][]Output{
			"claude/old":    {{Stdout: fixture(t, "claude-model.json"), Exit: 1}},
			"claude/sonnet": {{Stdout: fixture(t, "claude-ok.json")}},
		},
		next: []engine.Route{route("claude", "sonnet", "anthropic-max")},
	}
	res := Do(context.Background(), Request{First: route("claude", "old", "anthropic-max"), Harnesses: all}, f.deps())
	if !res.OK || res.Output != "The answer is 42." {
		t.Fatalf("result %+v", res)
	}
	if len(f.marks) != 1 || !strings.HasPrefix(f.marks[0], "model anthropic-max old ") {
		t.Errorf("marks %v", f.marks)
	}
}

func TestPinnedRouteNeverMoves(t *testing.T) {
	for _, req := range []Request{
		{First: route("grok", "grok-4.7", "xai-grok"), Pinned: true, Harnesses: []string{"grok"}},
		{First: engine.Route{Harness: "grok", Model: "grok-4.7", EntitlementPool: "xai-grok", Pinned: true}, Harnesses: []string{"grok"}},
	} {
		f := &fake{outputs: map[string][]Output{"grok/grok-4.7": {{Stdout: fixture(t, "grok-rate-limit.json"), Exit: 2}}},
			next: []engine.Route{route("grok", "grok-4.5", "xai-grok")}}
		res := Do(context.Background(), req, f.deps())
		if res.OK || res.Attempts != 1 || res.Exit != 2 || len(f.asked) != 0 {
			t.Fatalf("result %+v asked %v", res, f.asked)
		}
		if res.Error != "429 Too Many Requests" {
			t.Errorf("error %q", res.Error)
		}
		// Even a pinned failure is recorded for the router.
		want(t, "marks", f.marks, []string{"pool xai-grok grok-4.7 429 Too Many Requests"})
	}
}

func TestStopsAfterThreeAttempts(t *testing.T) {
	fail := Output{Exit: 1, Stderr: []byte("\x1b[31mboom\x1b[0m")}
	f := &fake{
		outputs: map[string][]Output{"claude/a": {fail}, "codex/b": {fail}, "opencode/c": {fail}, "grok/d": {{Stdout: []byte(`{"result":"never"}`)}}},
		next:    []engine.Route{route("codex", "b", "p2"), route("opencode", "c", "p3"), route("grok", "d", "p4")},
	}
	res := Do(context.Background(), Request{First: route("claude", "a", "p1"), Harnesses: all}, f.deps())
	if res.OK || res.Attempts != MaxAttempts || res.Exit != 1 || res.NoOther {
		t.Fatalf("result %+v", res)
	}
	want(t, "tried", res.Tried, []string{"claude/a", "codex/b", "opencode/c"})
	want(t, "escape codes removed", res.Error, "[31mboom[0m")
}

func TestStopsWhenNothingElseIsUsable(t *testing.T) {
	f := &fake{outputs: map[string][]Output{"claude/a": {{Exit: 1, Stderr: []byte("segfault")}}}}
	res := Do(context.Background(), Request{First: route("claude", "a", "p1"), Harnesses: []string{"claude"}}, f.deps())
	if res.OK || !res.NoOther || res.Attempts != 1 || len(f.asked) != 0 {
		// The only CLI failed with an "other" error: nothing is left to ask.
		t.Fatalf("result %+v asked %v", res, f.asked)
	}
	f = &fake{outputs: map[string][]Output{"claude/a": {{Stdout: fixture(t, "claude-usage-limit.json")}}}}
	res = Do(context.Background(), Request{First: route("claude", "a", "p1"), Harnesses: all}, f.deps())
	if !res.NoOther || len(f.asked) != 1 {
		t.Fatalf("the router had nothing: %+v asked %v", res, f.asked)
	}
}

func TestARouteAlreadyTriedIsNotTriedAgain(t *testing.T) {
	// The router answers with the route that just failed (it could not
	// see the failure): the run moves off that CLI instead.
	f := &fake{
		outputs: map[string][]Output{
			"claude/a": {{Stdout: fixture(t, "claude-usage-limit.json")}},
			"codex/b":  {{Stdout: fixture(t, "codex-ok.jsonl"), Answer: fixture(t, "codex-answer.txt")}},
		},
		next: []engine.Route{route("claude", "a", "p1"), route("codex", "b", "p2")},
	}
	res := Do(context.Background(), Request{First: route("claude", "a", "p1"), Harnesses: all}, f.deps())
	if !res.OK || res.Output != "Codex says hello." || res.Attempts != 2 {
		t.Fatalf("result %+v", res)
	}
	want(t, "asked", f.asked, [][]string{all, {"codex", "opencode", "grok"}})
}

func TestLaunchErrorMovesOn(t *testing.T) {
	f := &fake{
		outputs: map[string][]Output{
			"claude/gw": {{LaunchError: "cannot launch claude / gw here: the gateway needs its key in $AFK_GATEWAY_KEY"}},
			"codex/b":   {{Stdout: fixture(t, "codex-ok.jsonl"), Answer: fixture(t, "codex-answer.txt")}},
		},
		next: []engine.Route{route("codex", "b", "p2")},
	}
	res := Do(context.Background(), Request{First: route("claude", "gw", "gateway"), Harnesses: all}, f.deps())
	if !res.OK || len(f.marks) != 0 {
		t.Fatalf("result %+v marks %v", res, f.marks)
	}
	want(t, "asked without claude", f.asked, [][]string{{"codex", "opencode", "grok"}})
}

func TestInterruptedRunStops(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	f := &fake{next: []engine.Route{route("codex", "b", "p2")}}
	d := f.deps()
	d.Run = func(context.Context, engine.Route, string) Output { cancel(); return Output{Exit: 130} }
	res := Do(ctx, Request{First: route("claude", "a", "p1"), Harnesses: all}, d)
	if !res.Interrupted || res.Exit != 130 || len(f.asked) != 0 || len(f.marks) != 0 {
		t.Fatalf("result %+v", res)
	}
}

func TestInterruptedWhileMarkingStops(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	f := &fake{outputs: map[string][]Output{"claude/a": {{Stdout: fixture(t, "claude-usage-limit.json")}}}}
	d := f.deps()
	d.Mark = func(Kind, string, string, string) { cancel() }
	res := Do(ctx, Request{First: route("claude", "a", "p1"), Pinned: true, Harnesses: all}, d)
	if !res.Interrupted || res.Exit != 130 {
		t.Fatalf("result %+v", res)
	}
}

func TestReasonIsShort(t *testing.T) {
	long := strings.Repeat("é", 2000)
	why := reason(Output{Exit: 1, Stderr: []byte(long)}, "", true)
	if len(why) > 600 || !strings.HasPrefix(long, why) {
		t.Errorf("reason is %d bytes or split a character", len(why))
	}
}

func want(t *testing.T, what string, got, wantV any) {
	t.Helper()
	if !reflect.DeepEqual(got, wantV) {
		t.Errorf("%s:\n got %#v\nwant %#v", what, got, wantV)
	}
}

// After a CLI ran stricter than asked, failover never loosens the mode.
func TestFailoverNeverEscalates(t *testing.T) {
	var modes []string
	f := &fake{next: []engine.Route{route("codex", "b", "p2"), route("grok", "c", "p3")}}
	d := f.deps()
	n := 0
	d.Run = func(_ context.Context, r engine.Route, mode string) Output {
		modes = append(modes, r.Harness+":"+mode)
		n++
		switch n {
		case 1:
			// pi can't do auto and ran in edits.
			return Output{Exit: 1, Stderr: []byte("boom"), Mode: "edits", ModeNote: "pi: can't run in auto, running in edits"}
		case 2:
			return Output{Exit: 1, Stderr: []byte("boom"), Mode: "edits"}
		}
		return Output{Stdout: fixture(t, "claude-ok.json"), Mode: "edits"}
	}
	res := Do(context.Background(), Request{First: route("pi", "a", "p1"), Harnesses: all, Mode: "auto"}, d)
	if !res.OK {
		t.Fatalf("%+v", res)
	}
	want(t, "modes", modes, []string{"pi:auto", "codex:edits", "grok:edits"})
	if len(f.notes) == 0 || !strings.Contains(f.notes[0], "running in edits") {
		t.Errorf("the downgrade was not noted: %v", f.notes)
	}
}

func TestFailoverSetting(t *testing.T) {
	spent := func() map[string][]Output {
		return map[string][]Output{
			"claude/opus":   {{Stdout: fixture(t, "claude-model.json"), Exit: 1}},
			"claude/sonnet": {{Stdout: fixture(t, "claude-usage-limit.json")}},
		}
	}
	first := route("claude", "opus", "anthropic-max")

	// none: the failure is reported (and recorded), nothing else is asked.
	f := &fake{outputs: spent(), next: []engine.Route{route("codex", "sol", "openai-plus")}}
	res := Do(context.Background(), Request{First: first, Harnesses: all, Failover: "none"}, f.deps())
	if res.OK || res.Attempts != 1 || len(f.asked) != 0 || len(f.marks) != 1 {
		t.Fatalf("none: %+v asked %v marks %v", res, f.asked, f.marks)
	}

	// same-pool: another model on the same CLI and plan is tried, and the
	// router is asked about that CLI only.
	f = &fake{outputs: spent(), next: []engine.Route{route("codex", "sol", "openai-plus"), route("claude", "sonnet", "anthropic-max")}}
	res = Do(context.Background(), Request{First: first, Harnesses: all, Failover: "same-pool"}, f.deps())
	want(t, "same-pool tried", res.Tried, []string{"claude/opus", "claude/sonnet"})
	for _, only := range f.asked {
		want(t, "same-pool asked", only, []string{"claude"})
	}
	if res.OK || !res.NoOther {
		t.Fatalf("same-pool: %+v", res)
	}

	// same-pool: a route on the same CLI through another pool (a gateway
	// model run by claude) is not taken.
	f = &fake{outputs: spent(), next: []engine.Route{route("claude", "qwen", "litellm-local")}}
	res = Do(context.Background(), Request{First: first, Harnesses: all, Failover: "same-pool"}, f.deps())
	if res.OK || !res.NoOther || res.Attempts != 1 {
		t.Fatalf("same-pool, other pool: %+v", res)
	}

	// same-pool: a better ranked route through another pool doesn't hide
	// a model the first plan still has.
	f = &fake{outputs: spent(), next: []engine.Route{route("claude", "qwen", "litellm-local"), route("claude", "sonnet", "anthropic-max")}}
	res = Do(context.Background(), Request{First: first, Harnesses: all, Failover: "same-pool"}, f.deps())
	want(t, "same-pool past another pool", res.Tried, []string{"claude/opus", "claude/sonnet"})
}

func TestAnAnswerAboutRateLimitsDoesNotMarkThePool(t *testing.T) {
	// The CLI delivered an answer in JSON, then exited non-zero. The
	// answer discusses HTTP 429; that says nothing about the plan.
	answer := `{"type":"result","is_error":false,"result":"Handle HTTP 429 and 401 with a quota-aware retry."}`
	f := &fake{
		outputs: map[string][]Output{
			"claude/opus": {{Stdout: []byte(answer), Exit: 1}},
		},
	}
	Do(context.Background(), Request{First: route("claude", "opus", "anthropic-max"), Harnesses: all}, f.deps())
	if len(f.marks) != 0 {
		t.Errorf("an answer was read as a pool failure: %v", f.marks)
	}
}

func TestAStackTraceLineNumberDoesNotMarkThePool(t *testing.T) {
	f := &fake{
		outputs: map[string][]Output{
			"codex/sol": {{Stderr: []byte("panic: boom\n  at runner.go line 1401\n  at main.go:429"), Exit: 2}},
		},
	}
	Do(context.Background(), Request{First: route("codex", "sol", "openai-plus"), Harnesses: all}, f.deps())
	if len(f.marks) != 0 {
		t.Errorf("a line number was read as a pool failure: %v", f.marks)
	}
}

func TestPlainTextErrorOnStdoutStillMarks(t *testing.T) {
	// Not JSON: the CLI printing its own error, not a model answer.
	f := &fake{
		outputs: map[string][]Output{
			"grok/grok-4": {{Stdout: []byte("Error: HTTP 429 Too Many Requests\n"), Exit: 1}},
		},
	}
	Do(context.Background(), Request{First: route("grok", "grok-4", "xai-grok"), Harnesses: all}, f.deps())
	if len(f.marks) != 1 || !strings.HasPrefix(f.marks[0], "pool xai-grok ") {
		t.Errorf("marks %v", f.marks)
	}
}
