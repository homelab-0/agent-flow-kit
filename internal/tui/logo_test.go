package tui

import (
	"bytes"
	"io"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/colorprofile"
	"github.com/charmbracelet/x/exp/teatest/v2"
)

func env(m map[string]string) func(string) string { return func(k string) string { return m[k] } }

func TestDetectLogos(t *testing.T) {
	for _, c := range []struct {
		env  map[string]string
		want LogoMode
	}{
		{map[string]string{"TERM": "xterm-kitty"}, LogosKitty},
		{map[string]string{"TERM": "xterm-256color", "KITTY_WINDOW_ID": "1"}, LogosKitty},
		{map[string]string{"TERM": "xterm-ghostty"}, LogosKitty},
		{map[string]string{"TERM": "xterm-256color", "TERM_PROGRAM": "ghostty"}, LogosKitty},
		{map[string]string{"TERM": "xterm-256color"}, LogosText},
		{map[string]string{"TERM": "xterm-256color", "TERM_PROGRAM": "WezTerm"}, LogosText},
		{map[string]string{"TERM": "xterm-kitty", "TMUX": "/tmp/tmux"}, LogosText},
		{map[string]string{"TERM": "xterm-kitty", "NO_COLOR": "1"}, LogosText},
		{map[string]string{"TERM": "xterm-kitty", "AFK_LOGOS": "text"}, LogosText},
		{map[string]string{"TERM": "xterm-256color", "AFK_LOGOS": "kitty"}, LogosKitty},
	} {
		if got := DetectLogos(env(c.env)); got != c.want {
			t.Errorf("%v: %s, want %s", c.env, got, c.want)
		}
	}
}

func TestSendLogos(t *testing.T) {
	var b bytes.Buffer
	ids, err := SendLogos(&b)
	if err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"claude", "codex", "grok-light", "grok-dark", "ollama-light", "vllm", "agentgateway"} {
		if _, ok := ids[n]; !ok {
			t.Errorf("no logo %s", n)
		}
	}
	out := b.String()
	if n := strings.Count(out, "\x1b_Ga=T,U=1,f=100"); n != len(ids) {
		t.Errorf("%d images sent, want %d", n, len(ids))
	}
	// Every escape is closed, and no chunk is over 4096 bytes.
	for _, part := range strings.Split(out, "\x1b\\") {
		if part == "" {
			continue
		}
		if !strings.HasPrefix(part, "\x1b_G") {
			t.Fatalf("stray bytes %q", part[:min(len(part), 20)])
		}
		if _, payload, _ := strings.Cut(part, ";"); len(payload) > 4096 {
			t.Errorf("chunk of %d bytes", len(payload))
		}
	}
}

func TestLogoCells(t *testing.T) {
	ids := Logos{"claude": logoBase, "grok-light": logoBase + 1, "grok-dark": logoBase + 2}
	c := fixtureCard(t, -1)
	dark := NewTheme(true).WithLogos(ids)
	s := join(dark.CardLines(c, 80, true))
	if !strings.Contains(s, placeholderCells) {
		t.Fatal("no placeholder cells in the card")
	}
	if !strings.Contains(s, "38;2;175;75;0m"+placeholderCells) {
		t.Errorf("claude's cells should carry its image id as the foreground:\n%q", s)
	}
	if !strings.Contains(s, "38;2;175;75;1m") || strings.Contains(s, "38;2;175;75;2m") {
		t.Error("a dark terminal should draw the light grok logo")
	}
	// Widths are unchanged: every line is as wide as with text tags.
	text := plainLines(join(NewTheme(true).CardLines(c, 80, true)))
	img := plainLines(s)
	for i := range text {
		if lenCells(text[i]) != lenCells(img[i]) {
			t.Errorf("line %d is %d cells with logos, %d with text", i, lenCells(img[i]), lenCells(text[i]))
		}
	}
	// A route with no logo keeps its text tag.
	if !strings.Contains(s, "GW") {
		t.Error("the gateway row should keep its GW tag")
	}
}

// The cells survive Bubble Tea's renderer: they reach the terminal intact
// with the id colour.
func TestLogoCellsSurviveTheRenderer(t *testing.T) {
	f := fixtures(t)
	m := New(f, Options{Prompt: framePrompt, Width: 80, FPS: 30, Dark: true, Loc: time.UTC,
		Now: func() time.Time { return frameNow }, Environ: []string{"PATH=/bin"}, Logos: Logos{"claude": logoBase}})
	tm := teatest.NewTestModel(t, m, teatest.WithInitialTermSize(80, 40), teatest.WithProgramOptions(tea.WithColorProfile(colorprofile.TrueColor)))
	var seen []byte
	teatest.WaitFor(t, tm.Output(), func(b []byte) bool {
		seen = append(seen[:0], b...)
		return bytes.Contains(b, []byte(" cancel"))
	}, teatest.WithDuration(5*time.Second))
	tm.Send(key("esc"))
	tm.WaitFinished(t, teatest.WithFinalTimeout(5*time.Second))
	rest, _ := io.ReadAll(tm.FinalOutput(t))
	all := string(append(seen, rest...))
	if !strings.Contains(all, placeholder+diac0+diac0) || !strings.Contains(all, placeholder+diac0+diac1) {
		t.Errorf("placeholder cells were lost by the renderer")
	}
	if !strings.Contains(all, "175;75;0m") {
		t.Errorf("the image id colour was lost by the renderer")
	}
}
