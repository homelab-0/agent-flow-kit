package tui

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/exp/golden"
	"github.com/charmbracelet/x/exp/teatest/v2"

	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
)

// fake is the engine for tests: the fixtures, no processes.
type fake struct {
	ex      *engine.Explain
	pools   *engine.Pools
	planErr error
	plans   []engine.Route
}

func (f *fake) Explain(context.Context, engine.RouteFlags, string) (*engine.Explain, error) {
	return f.ex, nil
}

func (f *fake) LaunchPlan(_ context.Context, r engine.Route, _ string, _ bool, _ []string, _ string) (*engine.LaunchPlan, error) {
	f.plans = append(f.plans, r)
	if f.planErr != nil {
		return nil, f.planErr
	}
	return &engine.LaunchPlan{Schema: engine.SchemaLaunchPlan, OK: true, Argv: []string{"/bin/true"}}, nil
}

func (f *fake) Pools(context.Context) (*engine.Pools, error) { return f.pools, nil }

func fixtures(t *testing.T) *fake {
	t.Helper()
	ex, p := fixtureData(t)
	return &fake{ex: ex, pools: p}
}

// cardModel is a card on the fixtures, driven by hand (no program).
func cardModel(t *testing.T, f *fake, width int, motion bool) *Model {
	t.Helper()
	m := New(f, Options{Prompt: framePrompt, Width: width, Motion: motion, FPS: 30, Dark: true,
		Now: func() time.Time { return frameNow }, Loc: time.UTC, Environ: []string{"PATH=/bin"}})
	m.Init()
	m.Update(explainMsg{ex: f.ex})
	m.Update(poolsMsg{f.pools})
	return m
}

func key(s string) tea.KeyPressMsg {
	switch s {
	case "enter":
		return tea.KeyPressMsg{Code: tea.KeyEnter}
	case "esc":
		return tea.KeyPressMsg{Code: tea.KeyEscape}
	case "tab":
		return tea.KeyPressMsg{Code: tea.KeyTab}
	case "down":
		return tea.KeyPressMsg{Code: tea.KeyDown}
	case "up":
		return tea.KeyPressMsg{Code: tea.KeyUp}
	}
	r := []rune(s)[0]
	return tea.KeyPressMsg{Code: r, Text: s}
}

func press(m *Model, keys ...string) {
	for _, k := range keys {
		m.Update(key(k))
	}
}

func TestFrameCardFilling(t *testing.T) {
	m := cardModel(t, fixtures(t), 80, true)
	for i := 0; i < 9; i++ { // 300ms at 30 fps
		m.stepFill()
	}
	compareFrame(t, "04-card-1-t300ms.txt", m.Render(), reasonLines)
}

func TestFillMatchesFrameTiming(t *testing.T) {
	m := cardModel(t, fixtures(t), 80, true)
	if m.card.Prog != 0 {
		t.Fatalf("the meters start empty, got %v", m.card.Prog)
	}
	for i := 0; i < 9; i++ {
		m.stepFill()
	}
	// 04-card-1 at 300ms: claude 7 cells, codex 4, grok 8.
	got := []int{meterCells(78, 10, m.card.Prog), meterCells(52, 10, m.card.Prog), meterCells(91, 10, m.card.Prog)}
	if got[0] != 7 || got[1] != 4 || got[2] != 8 {
		t.Errorf("meters at 300ms = %v (progress %.3f), want [7 4 8]", got, m.card.Prog)
	}
	n := 9
	for m.stepFill() {
		n++
	}
	if m.card.Prog != 1 || n > 20 {
		t.Errorf("the fill should settle at 1 within 650ms (20 frames), got %v after %d", m.card.Prog, n)
	}
}

func TestNoMotionShowsFullMeters(t *testing.T) {
	m := cardModel(t, fixtures(t), 80, false)
	if m.card.Prog != 1 {
		t.Fatalf("without motion the meters are full at once, got %v", m.card.Prog)
	}
}

func TestEffortCyclesWithinSupported(t *testing.T) {
	m := cardModel(t, fixtures(t), 80, false)
	var seen []string
	for i := 0; i < 5; i++ {
		press(m, "tab")
		seen = append(seen, m.card.Route(m.card.Sel).Effort)
	}
	if strings.Join(seen, ",") != "xhigh,max,low,medium,high" {
		t.Errorf("tab cycles %v", seen)
	}
	press(m, "tab")
	if out := ansi.Strip(m.Render()); !strings.Contains(out, "effort xhigh") || strings.Contains(out, "escalated") {
		t.Errorf("a chosen effort shows in the box without the escalation tag:\n%s", out)
	}
	press(m, "up") // the gateway row takes no effort
	press(m, "tab")
	if !strings.Contains(m.notice, "no effort") {
		t.Errorf("tab on a route without efforts says so, got %q", m.notice)
	}
}

func TestYoloNeedsTwoPresses(t *testing.T) {
	m := cardModel(t, fixtures(t), 80, false)
	press(m, "y")
	if m.card.Yolo || !strings.Contains(m.notice, "press y again") {
		t.Fatalf("one press only warns: yolo=%v notice=%q", m.card.Yolo, m.notice)
	}
	press(m, "j", "y")
	if m.card.Yolo {
		t.Fatal("another key in between disarms yolo")
	}
	press(m, "y")
	if !m.card.Yolo {
		t.Fatal("two presses in a row turn yolo on")
	}
	if out := ansi.Strip(m.Render()); !strings.Contains(out, " yolo ") {
		t.Errorf("yolo shows as a tag:\n%s", out)
	}
	press(m, "y")
	if m.card.Yolo {
		t.Fatal("y again turns yolo off")
	}
}

func TestLaterStepKeysSayLater(t *testing.T) {
	m := cardModel(t, fixtures(t), 80, false)
	press(m, "m")
	if !strings.Contains(m.notice, "model picker comes in a later step") {
		t.Errorf("m: %q", m.notice)
	}
	press(m, "w")
	if !strings.Contains(m.notice, "only this terminal") || strings.Contains(m.notice, "Orca") {
		t.Errorf("w: %q", m.notice)
	}
}

func TestEditPromptRoutesAgain(t *testing.T) {
	m := cardModel(t, fixtures(t), 80, false)
	press(m, "e")
	if m.st != sEdit {
		t.Fatal("e opens the prompt for editing")
	}
	for _, r := range " now" {
		m.Update(key(string(r)))
	}
	press(m, "enter")
	if m.st != sRouting || m.card.Prompt != framePrompt+" now" {
		t.Fatalf("enter routes the edited prompt again: state %v prompt %q", m.st, m.card.Prompt)
	}
}

func TestEscCancels(t *testing.T) {
	m := cardModel(t, fixtures(t), 80, false)
	press(m, "esc")
	if d := m.Decision(); !d.Cancelled || d.Launch {
		t.Fatalf("esc cancels: %+v", d)
	}
	if !strings.Contains(ansi.Strip(m.Render()), "nothing was started") {
		t.Error("the card left in scrollback says it was cancelled")
	}
}

func TestPlanRefusalShowsErrorAndNextBest(t *testing.T) {
	f := fixtures(t)
	f.planErr = &engine.PlanError{Reason: "codex is not signed in on this machine"}
	m := cardModel(t, f, 80, false)
	press(m, "j", "enter")
	m.Update(planMsg{err: f.planErr})
	out := ansi.Strip(m.Render())
	for _, want := range []string{"Can't launch codex / gpt-6.1-sol", "Codex is not signed in on this machine.", "use next best (claude / claude-fable-5-2)"} {
		if !strings.Contains(out, want) {
			t.Errorf("error dialog lacks %q:\n%s", want, out)
		}
	}
	f.planErr = nil
	press(m, "enter")
	m.Update(planMsg{plan: &engine.LaunchPlan{OK: true, Argv: []string{"/bin/true"}}})
	if d := m.Decision(); !d.Launch || d.Route.Harness != "claude" {
		t.Fatalf("enter launches the next best route: %+v", d)
	}
}

func TestEnvRefusalShowsError(t *testing.T) {
	m := cardModel(t, fixtures(t), 80, false)
	press(m, "enter")
	m.Update(planMsg{plan: &engine.LaunchPlan{OK: true, Argv: []string{"/bin/true"}, EnvFrom: map[string]string{"ANTHROPIC_AUTH_TOKEN": "CLAUDE_CODE_OAUTH_TOKEN"}}})
	if m.st != sError || !strings.Contains(m.errText, "plan login never goes to a gateway") {
		t.Fatalf("a plan that would copy a vendor variable is refused: state %v, %q", m.st, m.errText)
	}
}

func TestLaunchCarriesOverrides(t *testing.T) {
	f := fixtures(t)
	m := cardModel(t, f, 80, false)
	press(m, "j", "tab", "y", "y", "enter")
	m.Update(m.planCmd()())
	d := m.Decision()
	if !d.Launch || d.Route.Harness != "codex" || d.Route.Effort != "xhigh" || !d.Yolo {
		t.Fatalf("decision %+v", d)
	}
	if len(f.plans) != 1 || f.plans[0].Raw["effort"] != "xhigh" || f.plans[0].Raw["harness"] != "codex" {
		t.Fatalf("the engine is asked for the route as picked, got %+v", f.plans)
	}
	if !strings.Contains(ansi.Strip(m.Render()), "▌  CX codex") || strings.Contains(m.Render(), "esc cancel") {
		t.Error("the card left in scrollback shows the pick, without key hints")
	}
}

func TestCardMatchesRendering(t *testing.T) {
	// The program draws exactly the card the rendering layer draws.
	m := cardModel(t, fixtures(t), 80, false)
	press(m, "j", "j")
	if got, want := m.Render(), renderCard(fixtureCard(t, 2), 80); got != want {
		t.Errorf("program and rendering differ\n%s\n---\n%s", got, want)
	}
}

// --- teatest: the card as a running program ------------------------------

func TestProgramPickAndLaunch(t *testing.T) {
	f := fixtures(t)
	m := New(f, Options{Prompt: framePrompt, Width: 80, FPS: 30, Dark: true, Loc: time.UTC,
		Now: func() time.Time { return frameNow }, Environ: []string{"PATH=/bin"}})
	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(80, 40))
	teatest.WaitFor(t, tm.Output(), func(b []byte) bool { return bytes.Contains(b, []byte("esc cancel")) },
		teatest.WithDuration(5*time.Second))
	tm.Send(key("j"))
	tm.Send(key("j"))
	tm.Send(key("enter"))
	fm := tm.FinalModel(t, teatest.WithFinalTimeout(5*time.Second)).(*Model)
	d := fm.Decision()
	if !d.Launch || d.Route.Harness != "grok" {
		t.Fatalf("decision %+v", d)
	}
	golden.RequireEqual(t, []byte(strings.Join(plainLines(fm.Render()), "\n")))
}

func TestProgramYesSkipsCard(t *testing.T) {
	f := fixtures(t)
	m := New(f, Options{Prompt: framePrompt, Width: 80, FPS: 30, Yes: true, Environ: []string{"PATH=/bin"}})
	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(80, 40))
	fm := tm.FinalModel(t, teatest.WithFinalTimeout(5*time.Second)).(*Model)
	if d := fm.Decision(); !d.Launch || d.Route.Harness != "claude" || fm.Render() != "" {
		t.Fatalf("--yes launches the choice and leaves no card: %+v %q", d, fm.Render())
	}
}

func TestExplainFailureEnds(t *testing.T) {
	m := New(&fake{}, Options{Width: 80})
	m.Init()
	m.Update(explainMsg{err: errors.New("afk: --prefer must be balanced, cheap or best")})
	if d := m.Decision(); d.Err == nil || d.Launch {
		t.Fatalf("an engine failure ends the card with the error: %+v", d)
	}
}

func TestRoutingTimeoutShowsDialog(t *testing.T) {
	m := New(&fake{}, Options{Prompt: framePrompt, Width: 80})
	m.Init()
	m.Update(explainMsg{err: &engine.TimeoutError{Call: "explain"}})
	out := ansi.Strip(m.Render())
	if m.st != sError || !strings.Contains(out, "Can't route this task") || !strings.Contains(out, "did not answer explain in time") {
		t.Fatalf("a routing timeout shows the error dialog:\n%s", out)
	}
	f := fixtures(t)
	m.be = f
	cmd := m.onKey(key("r"))
	if m.st != sRouting || cmd == nil {
		t.Fatal("r routes again")
	}
}

func TestPlanTimeoutShowsDialogEvenWithYes(t *testing.T) {
	f := fixtures(t)
	m := New(f, Options{Prompt: framePrompt, Width: 80, Yes: true, Environ: []string{"PATH=/bin"}})
	m.Init()
	m.Update(explainMsg{ex: f.ex})
	m.Update(planMsg{err: &engine.TimeoutError{Call: "launch-plan"}})
	if m.st != sError || m.Decision().Err != nil {
		t.Fatalf("a launch-plan timeout shows the dialog: state %v %+v", m.st, m.Decision())
	}
}

// blocking is an engine that never answers until its context ends.
type blocking struct{ fake }

func (b *blocking) Explain(ctx context.Context, _ engine.RouteFlags, _ string) (*engine.Explain, error) {
	<-ctx.Done()
	return nil, ctx.Err()
}

func TestQuitCancelsEngineCalls(t *testing.T) {
	m := New(&blocking{}, Options{Width: 80})
	m.Init()
	done := make(chan struct{})
	go func() { m.explainCmd()(); close(done) }()
	m.Update(key("esc"))
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("ending the card cancels the engine call")
	}
}
