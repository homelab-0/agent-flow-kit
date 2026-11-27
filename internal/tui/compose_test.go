package tui

import (
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
	if !m.Decision().Cancelled || m.Render() != "" {
		t.Errorf("esc on an empty input quits and leaves nothing: %+v %q", m.Decision(), m.Render())
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
