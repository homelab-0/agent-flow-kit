package tui

import (
	"errors"
	"time"

	"github.com/charmbracelet/x/ansi"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/charmbracelet/x/exp/golden"
)

var designHeader = Header{Version: "0.9.0", Dir: "~/src/prox-ops", Branch: "main", Art: true}

// headerFrame is the header card of a design frame: the lines above the
// prompt or the composer.
func headerFrame(t *testing.T, name string) []string {
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
	for i, l := range ls {
		if strings.HasPrefix(l, "╰") {
			return ls[:i+1]
		}
	}
	t.Fatalf("%s has no header card", name)
	return nil
}

func compareHeader(t *testing.T, name string, pose Pose, status line) {
	t.Helper()
	want := headerFrame(t, name)
	have := plainLines(join(NewTheme(true).HeaderLines(designHeader, pose, status, 80)))
	if strings.Join(want, "\n") != strings.Join(have, "\n") {
		t.Errorf("%s differs\n--- frame\n%s\n--- header\n%s", name, strings.Join(want, "\n"), strings.Join(have, "\n"))
	}
}

func TestFrameHeaders(t *testing.T) {
	th := NewTheme(true)
	chill := line{sg(th.Dim, "Esc is chilling")}
	compareHeader(t, "01-welcome-1-t600ms.txt", Pose{Eyes: "closed"}, chill)
	compareHeader(t, "00-intro-5-t2400ms.txt", Pose{Eyes: "closed", Z: 1}, chill)
	compareHeader(t, "02-typing-2-t2400ms.txt", Pose{Eyes: "peek"}, line{sg(th.Dim, "Esc opened one eye…")})
	compareHeader(t, "03-routing-3-t1200ms.txt", Pose{Stand: true, X: escStandX, Eyes: "right"},
		line{sg(th.Accent, "⠴ "), sg(th.Dim, "Esc is checking the options")})
	compareHeader(t, "04-card-2-t1600ms.txt", Pose{Stand: true, X: escStandX, Eyes: "lidded"},
		line{sg(th.Dim, "Esc suggests "), sg(th.Plain, "claude"), sg(th.Dim, ". Can I sit down now?")})
}

func TestGoldenHeader(t *testing.T) {
	th := NewTheme(true)
	h := Header{Version: "0.1.0", Dir: "~/src/acme-api", Branch: "main", Art: true}
	var out []string
	for _, p := range []Pose{
		{Eyes: "closed", Z: 3},
		{Stand: true, X: escStandX, Eyes: "lidded"},
		{Stand: true, X: escStandX, Eyes: "wide"},
	} {
		out = append(out, plainLines(join(th.HeaderLines(h, p, line{sg(th.Dim, "status")}, 80)))...)
	}
	h.Art = false
	out = append(out, plainLines(join(th.HeaderLines(h, Pose{}, line{sg(th.Dim, "status")}, 80)))...)
	golden.RequireEqual(t, []byte(strings.Join(out, "\n")))
}

func TestHomeDir(t *testing.T) {
	sep := string(os.PathSeparator)
	home := sep + "home" + sep + "j"
	for _, c := range [][2]string{
		{home, "~"},
		{home + sep + "src" + sep + "x", "~" + sep + "src" + sep + "x"},
		{sep + "tmp", sep + "tmp"},
		{sep + "home" + sep + "jx", sep + "home" + sep + "jx"},
	} {
		if got := HomeDir(c[0], home); got != c[1] {
			t.Errorf("HomeDir(%q) = %q, want %q", c[0], got, c[1])
		}
	}
}

func TestHeaderVersion(t *testing.T) {
	for v, want := range map[string]string{"0.1.0": " v0.1.0 · Agent Flow Kit", "v0.2.0": " v0.2.0 · Agent Flow Kit", "": " dev · Agent Flow Kit", "dev": " dev · Agent Flow Kit"} {
		if got := (Header{Version: v}).versionText(); got != want {
			t.Errorf("version %q: %q, want %q", v, got, want)
		}
	}
}

// headerModel is a card on the fixtures with the header card on.
func headerModel(t *testing.T, width int) *Model {
	t.Helper()
	f := fixtures(t)
	h := designHeader
	m := New(f, Options{Prompt: framePrompt, Width: width, Motion: false, FPS: 30, Dark: true,
		Now: func() time.Time { return frameNow }, Loc: time.UTC, Environ: []string{"PATH=/bin"}, Header: &h})
	m.Init()
	m.Update(explainMsg{ex: f.ex})
	m.Update(poolsMsg{f.pools})
	return m
}

func TestCardHasHeader(t *testing.T) {
	m := headerModel(t, 80)
	got := plainLines(m.Render())
	want := headerFrame(t, "04-card-2-t1600ms.txt")
	if strings.Join(got[:len(want)], "\n") != strings.Join(want, "\n") {
		t.Errorf("header above the card differs\n%s", strings.Join(got[:len(want)], "\n"))
	}
	if !strings.HasPrefix(got[len(want)], "› ") {
		t.Errorf("the prompt should follow the header, got %q", got[len(want)])
	}
}

func TestHeaderFollowsTheCard(t *testing.T) {
	m := headerModel(t, 80)
	press(m, "down")
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "Esc suggests claude") {
		t.Errorf("moving the selection should keep the router's pick in the status line:\n%s", s)
	}
	m.Update(planMsg{err: errors.New("codex is not signed in")})
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "Esc needs you.") || !strings.Contains(s, "!") {
		t.Errorf("an error should show Esc needing you:\n%s", s)
	}
}

func TestNoHeaderWhenNarrow(t *testing.T) {
	m := headerModel(t, 60)
	if s := ansi.Strip(m.Render()); strings.Contains(s, "Agent Flow Kit") {
		t.Errorf("the compact card has no header:\n%s", s)
	}
}

func TestCancelPutsEscBack(t *testing.T) {
	m := headerModel(t, 80)
	press(m, "esc")
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "Esc went back to sleep.") {
		t.Errorf("cancel should put Esc back in the hammock:\n%s", s)
	}
}
