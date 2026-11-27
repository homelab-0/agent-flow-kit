package tui

import (
	"bytes"
	"encoding/base64"
	"fmt"
	"hash/fnv"
	"image"
	"image/color"
	"image/png"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	uv "github.com/charmbracelet/ultraviolet"
	"github.com/charmbracelet/x/ansi"
)

// Terminals with iTerm2 inline images or Sixel get real logo images, drawn
// over the pixel marks. Bubble Tea's cell renderer can't carry either
// (it drops OSC 1337, and Sixel moves the cursor), so an overlay draws
// them after each frame: it finds each pixel mark in the frame's text,
// saves the cursor, moves to the mark, draws the image there, and puts
// the cursor back. The marks stay in the cells underneath, so a logo the
// overlay can't place (the last screen row, a frame it hasn't caught up
// with) still shows as its mark.

// ImageProto is how the overlay draws an image.
type ImageProto string

const (
	ProtoITerm ImageProto = "iterm" // OSC 1337 inline images (iTerm2, WezTerm)
	ProtoSixel ImageProto = "sixel"
)

// Overlay draws logo images over a program's frames.
type Overlay struct {
	proto ImageProto
	// probing: a Sixel candidate waiting for the terminal's answers.
	probing      bool
	da1          bool // the terminal answered DA1
	sixel        bool // ... and listed Sixel
	cellW, cellH int
	cellAsked    bool // the terminal answered CSI 16 t
	bg           color.Color

	needles map[string]string // a pixel mark as rendered → logo name
	imgs    map[string]string // logo name → its escape sequence

	rows, cols int
	top        int  // the inline frame's first screen row (1-based); 0 unknown
	sized      bool // a window size has arrived
	lost       bool // the inline frame moved in a way the overlay can't follow
	holding    bool // waiting for the cursor position before the first frame
	gen        int
	drawn      string // signature of the frame last drawn on
}

// NewOverlay is the overlay for this terminal, or nil when it draws no
// images this way: kitty-placeholder terminals, tmux, NO_COLOR and
// AFK_LOGOS=text|pixel|kitty never get one. iTerm2 and WezTerm use iTerm2
// images; any other terminal is asked whether it draws Sixel.
func NewOverlay(getenv func(string) string) *Overlay {
	mode := strings.ToLower(getenv("AFK_LOGOS"))
	switch mode {
	case "text", "off", "pixel", "blocks", "kitty":
		return nil
	}
	if getenv("NO_COLOR") != "" || getenv("TMUX") != "" || strings.HasPrefix(getenv("TERM"), "screen") {
		return nil
	}
	if mode != "iterm" && mode != "sixel" && DetectLogos(getenv) != LogosPixel {
		return nil // kitty images already
	}
	o := &Overlay{needles: map[string]string{}, imgs: map[string]string{}, holding: true}
	prog := getenv("TERM_PROGRAM")
	switch {
	case mode == "iterm", mode != "sixel" && (getenv("LC_TERMINAL") == "iTerm2" || prog == "iTerm.app" || prog == "WezTerm"):
		o.proto = ProtoITerm
	default:
		// Asked at start: does it draw Sixel, and how big is a cell?
		o.proto, o.probing, o.sixel = ProtoSixel, true, mode == "sixel"
	}
	// Two logos with the same mark can't be told apart: neither is drawn.
	twice := map[string]bool{}
	for name, m := range pixelMarks() {
		n := markSeg(m).s
		if _, ok := o.needles[n]; ok {
			twice[n] = true
		}
		o.needles[n] = name
	}
	for n := range twice {
		delete(o.needles, n)
	}
	return o
}

// cellSize is the fallback for a cell's size in pixels; tests replace it.
var cellSize = ttyCellSize

// Proto is how the overlay draws.
func (o *Overlay) Proto() ImageProto { return o.proto }

// The overlay's own messages.
type (
	overlayTick    struct{ gen int }
	overlayRelease struct{}
)

// WithOverlay wraps a program's model so its frames get logo images. A nil
// overlay returns m unchanged.
func WithOverlay(m tea.Model, o *Overlay) tea.Model {
	if o == nil {
		return m
	}
	return &overlayModel{inner: m, o: o}
}

type overlayModel struct {
	inner tea.Model
	o     *Overlay
}

func (m *overlayModel) Init() tea.Cmd {
	cmds := []tea.Cmd{m.inner.Init(), tea.RequestCursorPosition, tea.RequestBackgroundColor,
		tea.Tick(250*time.Millisecond, func(time.Time) tea.Msg { return overlayRelease{} })}
	if m.o.probing {
		// Cell size in pixels, then DA1, which every terminal answers.
		cmds = append(cmds, tea.Raw("\x1b[16t"+ansi.RequestPrimaryDeviceAttributes))
	}
	return tea.Batch(cmds...)
}

func (m *overlayModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	o := m.o
	switch msg := msg.(type) {
	case tea.CursorPositionMsg:
		if o.holding {
			o.top, o.holding = msg.Y+1, false
		}
	case overlayRelease:
		o.holding = false
	case uv.CellSizeEvent:
		o.cellW, o.cellH, o.cellAsked = msg.Width, msg.Height, true
		return m, m.schedule()
	case uv.PrimaryDeviceAttributesEvent:
		o.da1 = true
		for _, a := range msg {
			o.sixel = o.sixel || a == 4
		}
		o.probing = false
		if !o.cellAsked && o.cellW == 0 {
			// DA1 comes after CSI 16 t, so that went unanswered.
			o.cellW, o.cellH = cellSize()
		}
		return m, m.schedule()
	case tea.BackgroundColorMsg:
		o.bg = msg.Color
		o.imgs = map[string]string{} // Sixel images are drawn on it
	case tea.WindowSizeMsg:
		if o.sized && (msg.Width != o.cols || msg.Height != o.rows) {
			o.lost = true // the inline frame reflows somewhere new
			o.imgs = map[string]string{}
		}
		o.rows, o.cols, o.sized = msg.Height, msg.Width, true
		if !o.cellAsked && o.da1 {
			o.cellW, o.cellH = cellSize() // a font change resizes too
		}
	case overlayTick:
		if msg.gen != o.gen {
			return m, nil // a newer frame is coming
		}
		if seq := o.frame(m.inner.View()); seq != "" {
			return m, tea.Raw(seq)
		}
		return m, nil
	}
	var cmd tea.Cmd
	m.inner, cmd = m.inner.Update(msg)
	return m, tea.Batch(cmd, m.schedule())
}

// schedule draws on the frame once the renderer has written it: Bubble
// Tea writes raw output before each frame, so the images go out on a
// later tick than the frame they belong to.
func (m *overlayModel) schedule() tea.Cmd {
	m.o.gen++
	gen := m.o.gen
	return tea.Tick(60*time.Millisecond, func(time.Time) tea.Msg { return overlayTick{gen} })
}

func (m *overlayModel) View() tea.View {
	if m.o.holding {
		return tea.NewView("") // the cursor still marks where the frame starts
	}
	return m.inner.View()
}

// Inner is the wrapped model.
func (m *overlayModel) Inner() tea.Model { return m.inner }

// ready reports whether the overlay can draw at all.
func (o *Overlay) ready() bool {
	switch o.proto {
	case ProtoITerm:
		return true
	case ProtoSixel:
		return o.sixel && o.cellW > 0 && o.cellH >= 6
	}
	return false
}

// place is a logo at a frame position (0-based row and cell column).
type place struct {
	name     string
	row, col int
}

// locate finds every pixel mark in a frame's text.
func (o *Overlay) locate(content string) []place {
	var out []place
	for row, l := range strings.Split(content, "\n") {
		for needle, name := range o.needles {
			from := 0
			for {
				i := strings.Index(l[from:], needle)
				if i < 0 {
					break
				}
				at := from + i
				out = append(out, place{name: name, row: row, col: ansi.StringWidth(l[:at])})
				from = at + len(needle)
			}
		}
	}
	return out
}

// frame is the escape sequence drawing the logos on v, or "" when there
// is nothing new to draw.
func (o *Overlay) frame(v tea.View) string {
	if !o.ready() || o.holding || o.rows == 0 {
		return ""
	}
	top := 1
	if !v.AltScreen {
		if o.lost || o.top == 0 {
			return ""
		}
		// A frame taller than the room below it scrolls the screen up;
		// it never comes back down.
		h := strings.Count(v.Content, "\n") + 1
		if o.top+h-1 > o.rows {
			o.top = max(o.rows-h+1, 1)
		}
		top = o.top
	}
	sum := fnv.New64a()
	fmt.Fprintf(sum, "%v|%d|%d|%d|", v.AltScreen, top, o.rows, o.cols)
	sum.Write([]byte(v.Content))
	sig := fmt.Sprintf("%x", sum.Sum64())
	if sig == o.drawn {
		return ""
	}
	o.drawn = sig
	var b strings.Builder
	for _, p := range o.locate(v.Content) {
		row := top + p.row
		// Never on the last row: an image there could scroll the screen.
		if row >= o.rows || p.col+2 > o.cols {
			continue
		}
		img := o.image(p.name)
		if img == "" {
			continue
		}
		// Blank the two cells first, so no part of the mark shows through
		// the image's transparent pixels.
		pos := ansi.CursorPosition(p.col+1, row)
		b.WriteString("\x1b7\x1b[m" + pos + "  " + pos)
		b.WriteString(img)
		b.WriteString("\x1b8")
	}
	return b.String()
}

// image is a logo's escape sequence, made once.
func (o *Overlay) image(name string) string {
	if s, ok := o.imgs[name]; ok {
		return s
	}
	b, err := logoFS.ReadFile("logos/" + name + ".png")
	if err != nil {
		return ""
	}
	var s string
	switch o.proto {
	case ProtoITerm:
		s = itermImage(b)
	case ProtoSixel:
		img, err := png.Decode(bytes.NewReader(b))
		if err == nil {
			s = sixelImage(img, 2*o.cellW, o.cellH/6*6, o.bg)
		}
	}
	o.imgs[name] = s
	return s
}

// itermImage is an iTerm2 inline image filling 2×1 cells. The cursor
// stays where it was (doNotMoveCursor, iTerm2 3.5 and WezTerm); the
// overlay puts it back either way.
func itermImage(pngData []byte) string {
	return fmt.Sprintf("\x1b]1337;File=inline=1;size=%d;width=2;height=1;preserveAspectRatio=1;doNotMoveCursor=1:%s\a",
		len(pngData), base64.StdEncoding.EncodeToString(pngData))
}

// sixelImage is img scaled to fit w×h pixels (h a multiple of 6, so it
// stays inside its cell row), on bg, as Sixel. Colours come from a 6×6×6
// cube, which is plenty for a 2-cell logo.
func sixelImage(img image.Image, w, h int, bg color.Color) string {
	if w <= 0 || h <= 0 {
		return ""
	}
	if bg == nil {
		bg = color.Black
	}
	// Fit the image, keeping its shape, centred; each pixel averages the
	// source area under it and is laid on bg.
	sb := img.Bounds()
	scale := min(float64(w)/float64(sb.Dx()), float64(h)/float64(sb.Dy()))
	dw, dh := max(int(float64(sb.Dx())*scale), 1), max(int(float64(sb.Dy())*scale), 1)
	ox, oy := (w-dw)/2, (h-dh)/2
	br, bgG, bb, _ := bg.RGBA()
	back := [3]float64{float64(br) / 0xffff, float64(bgG) / 0xffff, float64(bb) / 0xffff}
	level := func(v float64) int { return int(min(max(v, 0), 1)*5 + 0.5) } // 0..5
	idx := make([]int, w*h)
	used := map[int]bool{}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			px := [3]float64(back)
			if x >= ox && x < ox+dw && y >= oy && y < oy+dh {
				sx0 := sb.Min.X + (x-ox)*sb.Dx()/dw
				sy0 := sb.Min.Y + (y-oy)*sb.Dy()/dh
				sx1 := max(sb.Min.X+(x-ox+1)*sb.Dx()/dw, sx0+1)
				sy1 := max(sb.Min.Y+(y-oy+1)*sb.Dy()/dh, sy0+1)
				a := average(img, image.Rect(sx0, sy0, sx1, sy1))
				px = [3]float64{a.r*a.a + back[0]*(1-a.a), a.g*a.a + back[1]*(1-a.a), a.b*a.a + back[2]*(1-a.a)}
			}
			i := level(px[0])*36 + level(px[1])*6 + level(px[2])
			idx[y*w+x] = i
			used[i] = true
		}
	}
	var s strings.Builder
	// P2=1: pixels no colour sets stay as they are (there are none here).
	fmt.Fprintf(&s, "\x1bP0;1;0q\"1;1;%d;%d", w, h)
	for i := range 216 {
		if used[i] {
			fmt.Fprintf(&s, "#%d;2;%d;%d;%d", i, i/36*20, i/6%6*20, i%6*20)
		}
	}
	for band := 0; band < h; band += 6 {
		first := true
		for c := range 216 {
			if !used[c] {
				continue
			}
			var row []byte
			any := false
			for x := 0; x < w; x++ {
				bits := 0
				for k := 0; k < 6 && band+k < h; k++ {
					if idx[(band+k)*w+x] == c {
						bits |= 1 << k
					}
				}
				any = any || bits != 0
				row = append(row, byte(63+bits))
			}
			if !any {
				continue
			}
			if !first {
				s.WriteByte('$') // back to the band's start for the next colour
			}
			first = false
			fmt.Fprintf(&s, "#%d%s", c, sixelRLE(row))
		}
		if band+6 < h {
			s.WriteByte('-')
		}
	}
	s.WriteString("\x1b\\")
	return s.String()
}

// sixelRLE compresses runs: !<n><char>.
func sixelRLE(row []byte) string {
	var b strings.Builder
	for i := 0; i < len(row); {
		j := i
		for j < len(row) && row[j] == row[i] {
			j++
		}
		if n := j - i; n > 3 {
			fmt.Fprintf(&b, "!%d%c", n, row[i])
		} else {
			b.Write(row[i:j])
		}
		i = j
	}
	return b.String()
}
