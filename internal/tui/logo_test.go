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
		{map[string]string{"TERM": "xterm-256color"}, LogosPixel},
		{map[string]string{"TERM": "xterm-256color", "TERM_PROGRAM": "WezTerm"}, LogosPixel},
		{map[string]string{"TERM": "xterm-256color", "TERM_PROGRAM": "iTerm.app"}, LogosPixel},
		{map[string]string{"TERM": "foot"}, LogosPixel},
		{map[string]string{"TERM": "tmux-256color", "TMUX": "/tmp/tmux"}, LogosPixel},
		{map[string]string{"TERM": "tmux-256color", "TMUX": "/tmp/tmux", "KITTY_WINDOW_ID": "1"}, LogosKittyTmux},
		{map[string]string{"TERM": "tmux-256color", "TMUX": "/tmp/tmux", "GHOSTTY_RESOURCES_DIR": "/usr/share/ghostty"}, LogosKittyTmux},
		// TERM inside tmux names tmux's terminal, not the outer one.
		{map[string]string{"TERM": "xterm-kitty", "TMUX": "/tmp/tmux"}, LogosPixel},
		{map[string]string{"TERM": "xterm-kitty", "NO_COLOR": "1"}, LogosText},
		{map[string]string{"TERM": "xterm-kitty", "AFK_LOGOS": "text"}, LogosText},
		{map[string]string{"TERM": "xterm-kitty", "AFK_LOGOS": "pixel"}, LogosPixel},
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

func TestSetupLogos(t *testing.T) {
	kittyTmux := map[string]string{"TERM": "tmux-256color", "TMUX": "/tmp/tmux", "KITTY_WINDOW_ID": "1"}
	tmux := func(pass, feat string) func(string) string {
		return func(f string) string {
			switch f {
			case "#{allow-passthrough}":
				return pass
			case "#{client_termfeatures}":
				return feat
			}
			return ""
		}
	}
	for _, c := range []struct {
		name     string
		env      map[string]string
		tmux     func(string) string
		images   bool
		hint     string
		textOnly bool
	}{
		{"kitty", map[string]string{"TERM": "xterm-kitty"}, nil, true, "", false},
		{"wezterm", map[string]string{"TERM_PROGRAM": "WezTerm"}, nil, false, "", false},
		{"no colour", map[string]string{"TERM": "xterm-kitty", "NO_COLOR": "1"}, nil, false, "", true},
		{"tmux passes images", kittyTmux, tmux("on", "256,RGB,title"), true, "", false},
		{"tmux passthrough off", kittyTmux, tmux("off", "256,RGB"), false, "allow-passthrough on", false},
		{"tmux without RGB", kittyTmux, tmux("all", "256,title"), false, "RGB", false},
	} {
		var b bytes.Buffer
		l, hint := SetupLogos(&b, env(c.env), c.tmux)
		if c.textOnly {
			if l != nil || b.Len() > 0 {
				t.Errorf("%s: want text tags, got %v", c.name, l)
			}
			continue
		}
		if got := l["claude"] != 0; got != c.images {
			t.Errorf("%s: images %v, want %v", c.name, got, c.images)
		}
		if c.images != (b.Len() > 0) {
			t.Errorf("%s: %d bytes sent to the terminal", c.name, b.Len())
		}
		if _, ok := l["claude"]; !ok {
			t.Errorf("%s: claude has no logo", c.name)
		}
		if c.hint == "" && hint != "" || !strings.Contains(hint, c.hint) {
			t.Errorf("%s: hint %q, want %q", c.name, hint, c.hint)
		}
	}
	// Through tmux, every chunk is wrapped and its ESCs doubled.
	var b bytes.Buffer
	SetupLogos(&b, env(kittyTmux), tmux("on", "RGB"))
	for _, part := range strings.SplitAfter(b.String(), "\x1b\x1b\\\x1b\\") {
		if part != "" && !strings.HasPrefix(part, "\x1bPtmux;\x1b\x1b_G") {
			t.Fatalf("unwrapped bytes %q", part[:min(len(part), 30)])
		}
	}
}

func TestPixelMarks(t *testing.T) {
	m := pixelMarks()
	for _, n := range []string{"claude", "codex", "copilot", "vllm"} {
		if _, ok := m[n]; !ok {
			t.Errorf("no pixel mark for %s", n)
		}
	}
	// Thin line art would be specks, so it keeps its tag.
	if _, ok := m["grok-light"]; ok {
		t.Error("grok's line art should keep its text tag")
	}
	// Claude's mark is its orange, filling both cells.
	c := m["claude"]
	if c[0].ch != "█" || c[1].ch != "█" {
		t.Errorf("claude's mark is %q%q", c[0].ch, c[1].ch)
	}
	if r, g, b, _ := c[0].fg.RGBA(); r>>8 < 0xc0 || g>>8 > 0x90 || b>>8 > 0x70 {
		t.Errorf("claude's mark is not orange: %02x%02x%02x", r>>8, g>>8, b>>8)
	}

	// In the card the marks replace the tags, and every line keeps its width.
	card := fixtureCard(t, -1)
	pix := join(NewTheme(true).WithLogos(PixelLogos()).CardLines(card, 80, true))
	text := plainLines(join(NewTheme(true).CardLines(card, 80, true)))
	got := plainLines(pix)
	if !strings.Contains(pix, "██") || strings.Contains(strings.Join(got, "\n"), "CL claude") {
		t.Errorf("claude should be drawn as its mark:\n%s", strings.Join(got, "\n"))
	}
	if !strings.Contains(strings.Join(got, "\n"), "GK grok") {
		t.Error("grok should keep its tag")
	}
	for i := range text {
		if lenCells(text[i]) != lenCells(got[i]) {
			t.Errorf("line %d is %d cells with marks, %d with text", i, lenCells(got[i]), lenCells(text[i]))
		}
	}
}

func TestQuadCell(t *testing.T) {
	red, blue := rgba{1, 0, 0, 1, 0}, rgba{0, 0, 1, 1, 0}
	clear := rgba{}
	for _, c := range []struct {
		q  [4]rgba
		ch string
		bg bool
	}{
		{[4]rgba{clear, clear, clear, clear}, " ", false},
		{[4]rgba{red, red, clear, clear}, "▀", false},
		{[4]rgba{red, clear, clear, red}, "▚", false},
		{[4]rgba{red, red, red, red}, "█", false},
		{[4]rgba{red, red, blue, blue}, "▀", true},
		{[4]rgba{blue, red, red, red}, "▟", true},
	} {
		got := quadCell(c.q)
		if got.ch != c.ch || (got.bg != nil) != c.bg {
			t.Errorf("%v: %q bg=%v, want %q bg=%v", c.q, got.ch, got.bg != nil, c.ch, c.bg)
		}
	}
}
