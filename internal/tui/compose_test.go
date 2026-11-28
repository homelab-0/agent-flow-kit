package tui

import (
	"context"

	tea "charm.land/bubbletea/v2"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
	"github.com/charmbracelet/x/exp/golden"
)

// composeModel is plain `afk` on the fixtures, at a clock the test moves.
func composeModel(t *testing.T, width int, motion bool) (*Model, *time.Time) {
	t.Helper()
	f := fixtures(t)
	h := designHeader
	now := frameNow
	m := New(f, Options{Width: width, Motion: motion, FPS: 30, Dark: true, Compose: true,
		Now: func() time.Time { return now }, Loc: time.UTC, Environ: []string{"PATH=/bin"}, Header: &h})
	m.Init()
	m.Update(previewMsg{f.ex})
	m.Update(poolsMsg{f.pools})
	return m, &now
}

func typeText(m *Model, s string) {
	for _, r := range s {
		m.Update(key(string(r)))
	}
}

// composerFrame is the composer block at the bottom of a design frame.
func composerFrame(t *testing.T, name string) []string {
	t.Helper()
	dir := os.Getenv("AFK_DESIGN_FRAMES")
	if dir == "" {
		t.Skip("AFK_DESIGN_FRAMES is not set; the design frames are not in the repository")
	}
	b, err := os.ReadFile(filepath.Join(dir, name))
	if err != nil {
		t.Fatal(err)
	}
	ls := plainLines(string(b))
	for len(ls) > 0 && ls[len(ls)-1] == "" {
		ls = ls[:len(ls)-1]
	}
	return ls[len(ls)-3:]
}

func TestIntroPlaysThenComposer(t *testing.T) {
	m, now := composeModel(t, 80, true)
	if m.st != sIntro {
		t.Fatalf("state %d, want the intro", m.st)
	}
	*now = frameNow.Add(600 * time.Millisecond)
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "Esc is heading to the hammock…") || strings.Contains(s, "Describe a task") {
		t.Errorf("at 600ms Esc should be walking in, with no input bar yet:\n%s", s)
	}
	*now = frameNow.Add(1500 * time.Millisecond)
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "*yawn*") {
		t.Errorf("at 1.5s Esc should yawn:\n%s", s)
	}
	*now = frameNow.Add(2400 * time.Millisecond)
	m.Update(escMsg{})
	if m.st != sCompose {
		t.Fatalf("state %d after 2.4s, want the composer", m.st)
	}
	got := plainLines(m.Render())
	want := headerFrame(t, "00-intro-5-t2400ms.txt")
	if strings.Join(got[:len(want)], "\n") != strings.Join(want, "\n") {
		t.Errorf("header at 2.4s differs from the frame:\n%s", strings.Join(got[:len(want)], "\n"))
	}
}

func TestAnyKeySkipsTheIntroAndIsKept(t *testing.T) {
	m, _ := composeModel(t, 80, true)
	typeText(m, "fix it")
	if m.st != sCompose || m.cin.Value() != "fix it" {
		t.Fatalf("state %d, input %q", m.st, m.cin.Value())
	}
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "Esc opened one eye…") || !strings.Contains(s, "› fix it▏") {
		t.Errorf("typing should show in the bar and wake one eye:\n%s", s)
	}
}

func TestComposerMatchesTheFrame(t *testing.T) {
	m, _ := composeModel(t, 80, false)
	got := plainLines(m.Render())
	want := composerFrame(t, "00-intro-5-t2400ms.txt")
	n := len(got)
	if got[n-3] != want[0] || got[n-1] != want[2] {
		t.Errorf("input bar or hint line differs\n--- frame\n%s\n--- composer\n%s", strings.Join(want, "\n"), strings.Join(got[n-3:], "\n"))
	}
	if !strings.HasPrefix(got[n-2], "  balanced · auto  CL 78%  CX 52%  GK 91%") {
		t.Errorf("status line %q", got[n-2])
	}
	golden.RequireEqual(t, []byte(strings.Join(got, "\n")))
}

func TestComposerRoutesTheTask(t *testing.T) {
	m, _ := composeModel(t, 80, false)
	m.Update(key("tab"))
	m.Update(key("tab"))
	typeText(m, "/harness codex")
	m.Update(key("enter"))
	if m.opt.Flags.Harness != "codex" || m.st != sCompose {
		t.Fatalf("/harness should pin codex and stay in the composer: %+v state %d", m.opt.Flags, m.st)
	}
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "quick · harness codex") {
		t.Errorf("the status line should show the task and the pin:\n%s", s)
	}
	typeText(m, "fix the flaky test")
	m.Update(key("enter"))
	if m.st != sRouting || m.card.Prompt != "fix the flaky test" || m.opt.Flags.Task != "quick" {
		t.Fatalf("enter should route: state %d prompt %q flags %+v", m.st, m.card.Prompt, m.opt.Flags)
	}
}

func TestComposerCommandsAndKeys(t *testing.T) {
	m, _ := composeModel(t, 80, false)
	typeText(m, "/nope")
	m.Update(key("enter"))
	if !strings.Contains(ansi.Strip(m.Render()), "unknown command /nope") {
		t.Error("an unknown command should say so")
	}
	typeText(m, "/prefer fast")
	m.Update(key("enter"))
	if m.opt.Flags.Prefer != "" {
		t.Error("a bad prefer mode should not be pinned")
	}
	m.Update(key("?"))
	if !strings.Contains(ansi.Strip(m.Render()), "pin a choice") {
		t.Error("? on an empty input shows the shortcuts")
	}
	m.Update(key("esc"))
	typeText(m, "a?")
	if m.cin.Value() != "a?" {
		t.Errorf("? inside text is text, got %q", m.cin.Value())
	}
	m.Update(key("esc"))
	if m.cin.Value() != "" || m.st != sCompose {
		t.Error("esc clears the input first")
	}
	m.Update(key("esc"))
	if m.st != sCompose || m.Decision().Cancelled || !strings.Contains(ansi.Strip(m.Render()), "ctrl+c twice") {
		t.Errorf("esc on an empty input stays in AFK and says how to leave: %+v", m.Decision())
	}
}

var ctrlC = tea.KeyPressMsg{Code: 'c', Mod: tea.ModCtrl}

// AFK is left on purpose: ctrl+c clears the input, a second one asks, and
// only a third in a row (or ctrl+d on an empty input) ends it.
func TestComposerLeavesOnlyOnPurpose(t *testing.T) {
	m, _ := composeModel(t, 100, false)
	typeText(m, "fix it")
	m.Update(ctrlC)
	if m.cin.Value() != "" || m.st != sCompose {
		t.Fatal("ctrl+c clears the input first")
	}
	m.Update(ctrlC)
	if m.st != sCompose || !strings.Contains(ansi.Strip(m.Render()), exitHint) {
		t.Fatal("one ctrl+c on an empty input only asks")
	}
	typeText(m, "a")
	m.Update(ctrlC) // clears "a"; the earlier ctrl+c no longer counts
	m.Update(ctrlC)
	if m.st != sCompose {
		t.Fatal("typing in between starts the count again")
	}
	m.Update(ctrlC)
	if d := m.Decision(); !d.Cancelled || !d.Exit || m.Render() != "" {
		t.Errorf("ctrl+c twice exits and leaves nothing: %+v %q", d, m.Render())
	}

	m, _ = composeModel(t, 100, false)
	typeText(m, "a")
	m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
	if m.Decision().Cancelled {
		t.Error("ctrl+d with text typed does not exit")
	}
	m.Update(ctrlC)
	m.Update(tea.KeyPressMsg{Code: 'd', Mod: tea.ModCtrl})
	if d := m.Decision(); !d.Exit {
		t.Errorf("ctrl+d on an empty input exits: %+v", d)
	}
}

// Dropping a prompt's card is not leaving AFK, and the slash-command pins
// come back with the decision so the next composer keeps them.
func TestCancelledCardIsNotAnExit(t *testing.T) {
	m, _ := composeModel(t, 100, false)
	typeText(m, "/harness codex")
	m.Update(key("enter"))
	typeText(m, "fix it")
	m.Update(key("enter"))
	m.Update(ctrlC)
	d := m.Decision()
	if !d.Cancelled || d.Exit || d.Prompt != "fix it" || d.Flags.Harness != "codex" {
		t.Errorf("got %+v", d)
	}
}

// Back from a session: no startup animation, the dropped prompt in the
// input, and a notice under it.
func TestComposerResumed(t *testing.T) {
	f := fixtures(t)
	h := designHeader
	m := New(f, Options{Width: 100, Motion: true, FPS: 30, Dark: true, Compose: true, Resumed: true,
		Draft: "fix it", Notice: "back in AFK", Now: func() time.Time { return frameNow }, Loc: time.UTC, Header: &h})
	m.Init()
	if m.st != sCompose || m.cin.Value() != "fix it" || !strings.Contains(ansi.Strip(m.Render()), "back in AFK") {
		t.Errorf("state %v, input %q", m.st, m.cin.Value())
	}
}

func TestComposerNarrowAndNoMotion(t *testing.T) {
	m, _ := composeModel(t, 60, true)
	if m.st != sCompose {
		t.Error("a narrow terminal skips the intro (there is no header)")
	}
	if s := ansi.Strip(m.Render()); strings.Contains(s, "Agent Flow Kit") || !strings.Contains(s, "Describe a task") {
		t.Errorf("narrow composer:\n%s", s)
	}
	m2, _ := composeModel(t, 80, false)
	if m2.st != sCompose {
		t.Error("without motion there is no intro")
	}
}

// progressFake reports routing steps before answering.
type progressFake struct {
	*fake
	steps []engine.Progress
}

func (f *progressFake) Explain(ctx context.Context, fl engine.RouteFlags, p string) (*engine.Explain, error) {
	for _, s := range f.steps {
		engine.ReportProgress(ctx, s)
	}
	return f.fake.Explain(ctx, fl, p)
}

func TestRoutingScreen(t *testing.T) {
	f := fixtures(t)
	rows, _ := f.ex.Rows()
	m := New(f, Options{Prompt: framePrompt, Width: 80, FPS: 30, Dark: true, Now: func() time.Time { return frameNow }})
	m.started = frameNow.Add(-400 * time.Millisecond)
	m.st = sRouting
	m.prog.add(engine.Progress{Kind: "start", Task: "coding", Guessed: true, Prefer: "balanced", Harnesses: []string{"claude", "codex", "grok", "opencode"}})
	m.prog.add(engine.Progress{Kind: "route", Harness: "claude", Route: &rows[0]})
	m.prog.add(engine.Progress{Kind: "route", Harness: "codex", Route: &rows[1]})
	m.prog.add(engine.Progress{Kind: "skip", Harness: "opencode"})
	got := plainLines(m.Render())
	want := []string{
		"› " + framePrompt,
		"",
		" · Routing  coding (guessed) · balanced · 4 routes",
		"   ✓ CL claude       claude-fable-5-2 SWE-bench Verified 78.1 measured",
		"   ✓ CX codex        gpt-6.1-sol      SWE-bench Verified 76.4 measured",
		"   · GK grok                          probing pool usage…",
		"   – OC opencode     no usable route for this task",
	}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Errorf("routing screen\n--- got\n%s\n--- want\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
}

func TestRoutingStepsReachTheModel(t *testing.T) {
	base := fixtures(t)
	f := &progressFake{fake: base, steps: []engine.Progress{{Kind: "start", Task: "coding", Prefer: "balanced", Harnesses: []string{"claude"}}}}
	m := New(f, Options{Prompt: framePrompt, Width: 80, FPS: 30, Dark: true})
	cmd := m.explainCmd()
	// Run the batch: the explain call and the listener.
	msgs := runBatch(cmd)
	var sawStart bool
	for _, msg := range msgs {
		if pm, ok := msg.(progressMsg); ok && !pm.done && pm.p.Kind == "start" {
			sawStart = true
		}
	}
	if !sawStart {
		t.Errorf("the start step never reached the model: %#v", msgs)
	}
}

// runBatch runs a command, and each command in a batch, once.
func runBatch(cmd tea.Cmd) []tea.Msg {
	msg := cmd()
	if b, ok := msg.(tea.BatchMsg); ok {
		var out []tea.Msg
		for _, c := range b {
			out = append(out, c())
		}
		return out
	}
	return []tea.Msg{msg}
}

// With RunHere, enter hands the prompt back to be run inside AFK, ctrl+o
// takes it to the route card, and an empty enter still goes to the card.
func TestComposerRunsHere(t *testing.T) {
	f := fixtures(t)
	h := designHeader
	mk := func() *Model {
		m := New(f, Options{Width: 100, FPS: 30, Dark: true, Compose: true, RunHere: true,
			Now: func() time.Time { return frameNow }, Loc: time.UTC, Environ: []string{"PATH=/bin"}, Header: &h})
		m.Init()
		return m
	}
	m := mk()
	if !strings.Contains(ansi.Strip(m.Render()), "↵ run · ctrl+o route card") {
		t.Errorf("the hint line:\n%s", ansi.Strip(m.Render()))
	}
	m.Update(key("tab")) // coding
	typeText(m, "fix it")
	m.Update(key("enter"))
	d := m.Decision()
	if !d.RunHere || d.Launch || d.Cancelled || d.Prompt != "fix it" || d.Flags.Task != "coding" {
		t.Fatalf("enter: %+v", d)
	}
	if last := plainLines(m.Render()); len(last) < 2 || !strings.Contains(strings.Join(last, "\n"), "› fix it") {
		t.Errorf("the prompt stays as the turn's first line:\n%s", strings.Join(last, "\n"))
	}

	m = mk()
	typeText(m, "fix it")
	m.Update(tea.KeyPressMsg{Code: 'o', Mod: tea.ModCtrl})
	if m.st != sRouting || m.Decision().RunHere {
		t.Errorf("ctrl+o goes to the route card: state %v", m.st)
	}

	m = mk()
	m.Update(key("enter"))
	if m.st != sRouting {
		t.Errorf("an empty enter still routes to the card: state %v", m.st)
	}
}

func TestModeCommand(t *testing.T) {
	m, _ := composeModel(t, 100, false)
	typeText(m, "/mode edits")
	m.Update(key("enter"))
	if m.opt.Flags.Perm != "edits" || !strings.Contains(ansi.Strip(m.Render()), "mode: edits") {
		t.Errorf("perm %q", m.opt.Flags.Perm)
	}
	typeText(m, "/mode yolo")
	m.Update(key("enter"))
	if m.opt.Flags.Perm != "edits" || !strings.Contains(ansi.Strip(m.Render()), "y y on the route card") {
		t.Error("yolo is not set from /mode")
	}
	typeText(m, "/mode")
	m.Update(key("enter"))
	if m.opt.Flags.Perm != "" {
		t.Error("/mode alone goes back to the default")
	}
}

func TestRateCommand(t *testing.T) {
	m, _ := composeModel(t, 100, false)
	typeText(m, "/rate 1")
	m.Update(key("enter"))
	if !strings.Contains(ansi.Strip(m.Render()), "nothing to rate yet") {
		t.Error("no run yet")
	}
	var got string
	m.opt.Rate = func(o string) string { got = o; return "rated r-1: " + o }
	for in, want := range map[string]string{"/rate 2": "partly", "/rate solved": "solved", "/rate 3": "wrong-pick"} {
		typeText(m, in)
		m.Update(key("enter"))
		if got != want || !strings.Contains(ansi.Strip(m.Render()), "rated r-1: "+want) {
			t.Errorf("%s: got %q", in, got)
		}
	}
	got = ""
	typeText(m, "/rate great")
	m.Update(key("enter"))
	if got != "" || !strings.Contains(ansi.Strip(m.Render()), "/rate 1 (solved)") {
		t.Error("a bad rating is explained, not saved")
	}
}

// /open reopens the last run's session in its CLI: it ends the composer
// with Decision.Open only when there is a session to open, and says why
// when there isn't.
func TestComposerOpensTheLastSession(t *testing.T) {
	m, _ := composeModel(t, 80, false)
	typeText(m, "/open")
	m.Update(key("enter"))
	if m.st != sCompose || m.Decision().Open || !strings.Contains(ansi.Strip(m.Render()), "nothing to open yet") {
		t.Errorf("no run yet: stays in the composer and says so, got %+v", m.Decision())
	}
	m.opt.CanOpen = func() string { return "grok didn't report a session id for the last run" }
	typeText(m, "/open")
	m.Update(key("enter"))
	if m.Decision().Open || !strings.Contains(ansi.Strip(m.Render()), "didn't report a session id") {
		t.Error("a run with no session id says why it can't be opened")
	}
	m.opt.CanOpen = func() string { return "" }
	typeText(m, "/open")
	m.Update(key("enter"))
	if d := m.Decision(); !d.Open || d.RunHere || d.Launch || d.Cancelled {
		t.Errorf("decision = %+v, want Open only", d)
	}
}
