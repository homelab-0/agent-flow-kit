package tui

import (
	"bytes"
	"context"
	"image"
	"image/color"
	"image/png"
	"regexp"
	"strconv"
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/ansi"
)

func envOf(kv ...string) func(string) string {
	m := map[string]string{}
	for i := 0; i+1 < len(kv); i += 2 {
		m[kv[i]] = kv[i+1]
	}
	return func(k string) string { return m[k] }
}

func TestNewOverlay(t *testing.T) {
	for _, c := range []struct {
		env  []string
		want ImageProto // "" no overlay
	}{
		{[]string{"TERM_PROGRAM", "iTerm.app"}, ProtoITerm},
		{[]string{"LC_TERMINAL", "iTerm2", "TERM", "xterm-256color"}, ProtoITerm},
		{[]string{"TERM_PROGRAM", "WezTerm"}, ProtoITerm},
		{[]string{"TERM", "foot"}, ProtoSixel}, // asked at start
		{[]string{"TERM", "xterm-kitty"}, ""},
		{[]string{"TERM_PROGRAM", "iTerm.app", "TMUX", "/tmp/x"}, ""},
		{[]string{"TERM_PROGRAM", "iTerm.app", "NO_COLOR", "1"}, ""},
		{[]string{"TERM_PROGRAM", "iTerm.app", "AFK_LOGOS", "pixel"}, ""},
		{[]string{"TERM", "xterm", "AFK_LOGOS", "iterm"}, ProtoITerm},
		{[]string{"TERM", "xterm-kitty", "AFK_LOGOS", "sixel"}, ProtoSixel},
	} {
		o := NewOverlay(envOf(c.env...))
		got := ImageProto("")
		if o != nil {
			got = o.Proto()
		}
		if got != c.want {
			t.Errorf("%v: %q, want %q", c.env, got, c.want)
		}
	}
}

// The overlay finds each pixel mark where the frame draws it, on a
// selected row too.
func TestOverlayLocate(t *testing.T) {
	o := NewOverlay(envOf("TERM_PROGRAM", "iTerm.app"))
	theme := NewTheme(true).WithLogos(PixelLogos())
	p := NewPanel(context.Background(), &fakePanel{}, theme, TabHarnesses, "0.2.0", nil)
	p.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	p.Update(p.Init()())
	content := p.View().Content
	places := o.locate(content)
	rows := strings.Split(content, "\n")
	found := map[string]bool{}
	for _, pl := range places {
		found[pl.name] = true
		// The two cells there are the mark's quadrant blocks.
		cells := ansi.Strip(ansi.Cut(rows[pl.row], pl.col, pl.col+2))
		if ansi.StringWidth(cells) != 2 || strings.TrimLeft(cells, " ▘▝▀▖▌▞▛▗▚▐▜▄▙▟█") != "" {
			t.Errorf("%s at %d,%d sits on %q", pl.name, pl.row, pl.col, cells)
		}
	}
	for _, n := range []string{"claude", "codex"} {
		if !found[n] {
			t.Errorf("%s not found in\n%s", n, content)
		}
	}
}

func TestOverlayFrames(t *testing.T) {
	o := NewOverlay(envOf("TERM_PROGRAM", "iTerm.app"))
	theme := NewTheme(true).WithLogos(PixelLogos())
	inner := PanelModel{P: NewPanel(context.Background(), &fakePanel{}, theme, TabHarnesses, "0.2.0", nil)}
	m := WithOverlay(inner, o).(*overlayModel)
	m.Init()
	if v := m.View(); v.Content != "" {
		t.Fatal("the first frame must wait for the cursor position")
	}
	m.Update(tea.CursorPositionMsg{X: 0, Y: 4})
	m.Update(tea.WindowSizeMsg{Width: 100, Height: 30})
	m.Update(inner.P.Init()())
	_, cmd := m.Update(overlayTick{gen: o.gen})
	if cmd == nil {
		t.Fatal("nothing drawn")
	}
	seq := string(cmd().(tea.RawMsg).Msg.(string))
	// The panel is on the alternate screen: rows count from 1.
	if !strings.Contains(seq, "\x1b7\x1b[m\x1b[") || !strings.Contains(seq, "]1337;File=inline=1;") || !strings.HasSuffix(seq, "\x1b8") {
		t.Fatalf("sequence %q", seq[:min(len(seq), 200)])
	}
	if c := regexp.MustCompile(`\x1b\[(\d+);(\d+)H`).FindStringSubmatch(seq); c == nil {
		t.Errorf("no cursor move in %q", seq[:80])
	}
	// The same frame again draws nothing; a stale tick draws nothing.
	if _, cmd := m.Update(overlayTick{gen: o.gen}); cmd != nil {
		t.Error("redrew an unchanged frame")
	}
	if _, cmd := m.Update(overlayTick{gen: o.gen - 1}); cmd != nil {
		t.Error("a stale tick drew")
	}
}

// Inline frames are placed from the cursor row the program started on,
// and move up when they outgrow the screen.
func TestOverlayInline(t *testing.T) {
	o := NewOverlay(envOf("TERM_PROGRAM", "iTerm.app"))
	o.holding, o.top, o.rows, o.cols = false, 20, 24, 80
	mark := markSeg(pixelMarks()["claude"]).s
	v := tea.NewView("title\n  " + mark + " claude")
	seq := o.frame(v)
	if !strings.Contains(seq, ansi.CursorPosition(3, 21)) {
		t.Errorf("want row 21 col 3 in %q", seq[:40])
	}
	o.drawn = ""
	v = tea.NewView(strings.Repeat("x\n", 9) + "  " + mark + "\nlast")
	seq = o.frame(v) // 11 rows from row 20 → the frame now starts at 14
	if o.top != 14 || !strings.Contains(seq, ansi.CursorPosition(3, 23)) {
		t.Errorf("top %d, seq %q", o.top, seq[:min(len(seq), 40)])
	}
	// The last screen row is never drawn on.
	o.drawn = ""
	v = tea.NewView(strings.Repeat("x\n", 10) + mark)
	if seq := o.frame(v); seq != "" {
		t.Errorf("drew on the last row: %q", seq[:min(len(seq), 40)])
	}
	// After a resize the inline frame's place is unknown: marks only.
	m := &overlayModel{inner: PanelModel{P: NewPanel(context.Background(), &fakePanel{}, NewTheme(true), TabHarnesses, "", nil)}, o: o}
	o.sized = true
	m.Update(tea.WindowSizeMsg{Width: 70, Height: 24})
	o.drawn = ""
	if seq := o.frame(tea.NewView("  " + mark)); seq != "" || !o.lost {
		t.Error("drew after a resize")
	}
}

func TestOverlaySixel(t *testing.T) {
	o := NewOverlay(envOf("TERM", "foot"))
	o.holding, o.top, o.rows, o.cols = false, 1, 24, 80
	mark := markSeg(pixelMarks()["claude"]).s
	if o.frame(tea.NewView(mark)) != "" {
		t.Error("drew before the terminal said it draws Sixel")
	}
	m := &overlayModel{inner: PanelModel{P: NewPanel(context.Background(), &fakePanel{}, NewTheme(true), TabHarnesses, "", nil)}, o: o}
	m.Update(uv.CellSizeEvent{Width: 9, Height: 20})
	m.Update(uv.PrimaryDeviceAttributesEvent{62, 4, 22})
	m.Update(tea.BackgroundColorMsg{Color: color.RGBA{0x10, 0x10, 0x20, 0xff}})
	o.drawn = ""
	seq := o.frame(tea.NewView(mark))
	if !strings.Contains(seq, "\x1bP0;1;0q\"1;1;18;18") {
		t.Fatalf("sixel header (18×18 for 9×20 cells) missing in %q", seq[:min(len(seq), 60)])
	}
	// No DA1 Sixel: nothing.
	o2 := NewOverlay(envOf("TERM", "xterm-256color"))
	o2.holding, o2.top, o2.rows, o2.cols = false, 1, 24, 80
	m2 := &overlayModel{inner: m.inner, o: o2}
	m2.Update(uv.CellSizeEvent{Width: 9, Height: 20})
	m2.Update(uv.PrimaryDeviceAttributesEvent{62, 22})
	if o2.frame(tea.NewView(mark)) != "" {
		t.Error("drew Sixel on a terminal without it")
	}
}

// decodeSixel turns sixelImage's output back into pixels.
func decodeSixel(t *testing.T, s string) *image.RGBA {
	t.Helper()
	m := regexp.MustCompile(`^\x1bP0;1;0q"1;1;(\d+);(\d+)`).FindStringSubmatch(s)
	if m == nil || !strings.HasSuffix(s, "\x1b\\") {
		t.Fatalf("not a sixel image: %q", s[:min(len(s), 40)])
	}
	w, _ := strconv.Atoi(m[1])
	h, _ := strconv.Atoi(m[2])
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	body := s[len(m[0]) : len(s)-2]
	pal := map[int]color.RGBA{}
	cur, x, band := 0, 0, 0
	num := func(i int) (int, int) {
		j := i
		for j < len(body) && body[j] >= '0' && body[j] <= '9' {
			j++
		}
		n, _ := strconv.Atoi(body[i:j])
		return n, j
	}
	put := func(c byte, n int) {
		bits := int(c) - 63
		for k := 0; k < n; k++ {
			for b := 0; b < 6; b++ {
				if bits&(1<<b) != 0 {
					img.Set(x, band*6+b, pal[cur])
				}
			}
			x++
		}
	}
	for i := 0; i < len(body); {
		switch c := body[i]; {
		case c == '#':
			n, j := num(i + 1)
			if j < len(body) && body[j] == ';' {
				var v [4]int
				k := j
				for q := 0; q < 4; q++ {
					v[q], k = num(k + 1)
				}
				pal[n] = color.RGBA{uint8(v[1] * 255 / 100), uint8(v[2] * 255 / 100), uint8(v[3] * 255 / 100), 255}
				i = k
				continue
			}
			cur, i = n, j
		case c == '!':
			n, j := num(i + 1)
			put(body[j], n)
			i = j + 1
		case c == '$':
			x, i = 0, i+1
		case c == '-':
			x, band, i = 0, band+1, i+1
		case c >= 63 && c <= 126:
			put(c, 1)
			i++
		default:
			t.Fatalf("unexpected %q at %d", c, i)
		}
	}
	return img
}

func TestSixelImage(t *testing.T) {
	b, _ := logoFS.ReadFile("logos/claude.png")
	src, _ := png.Decode(bytes.NewReader(b))
	bg := color.RGBA{0x10, 0x10, 0x20, 0xff}
	img := decodeSixel(t, sixelImage(src, 20, 18, bg))
	if img.Bounds().Dx() != 20 || img.Bounds().Dy() != 18 {
		t.Fatalf("size %v", img.Bounds())
	}
	// Every pixel is set (nothing shows through), the corners are the
	// background, and the middle is the logo's orange.
	for y := 0; y < 18; y++ {
		for x := 0; x < 20; x++ {
			if img.RGBAAt(x, y).A == 0 {
				t.Fatalf("pixel %d,%d unset", x, y)
			}
		}
	}
	c := img.RGBAAt(0, 0)
	if c.R > 0x40 || c.B > 0x40 {
		t.Errorf("corner %v, want the background", c)
	}
	mid := img.RGBAAt(10, 9)
	if mid.R < 0x99 || mid.B > mid.R {
		t.Errorf("middle %v, want the logo's colour", mid)
	}
}

func TestITermImage(t *testing.T) {
	s := itermImage([]byte("png"))
	if s != "\x1b]1337;File=inline=1;size=3;width=2;height=1;preserveAspectRatio=1;doNotMoveCursor=1:cG5n\a" {
		t.Errorf("%q", s)
	}
}
