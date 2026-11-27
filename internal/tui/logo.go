package tui

import (
	"embed"
	"encoding/base64"
	"fmt"
	"io"
	"strings"

	"charm.land/lipgloss/v2"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// Logos are drawn as images with the kitty graphics protocol's Unicode
// placeholders: each image is sent to the terminal once, before the card
// starts, and a logo in a row is then two ordinary text cells (U+10EEEE
// with diacritics for the row and column) whose foreground colour is the
// image id. The cells move, scroll and redraw like any text, so the card
// renderer needs no special handling. Terminals without placeholders get
// the 2-letter text tag in brand colours.

//go:embed logos/*.png
var logoFS embed.FS

// LogoMode is how route logos are drawn.
type LogoMode string

const (
	LogosText  LogoMode = "text"  // 2-letter tags in brand colours
	LogosKitty LogoMode = "kitty" // images through kitty Unicode placeholders
)

// DetectLogos picks the logo mode from the environment: kitty and Ghostty
// show images; everything else, tmux (which needs passthrough) and
// NO_COLOR get text. AFK_LOGOS=text or AFK_LOGOS=kitty overrides it.
func DetectLogos(getenv func(string) string) LogoMode {
	switch strings.ToLower(getenv("AFK_LOGOS")) {
	case "text", "off":
		return LogosText
	case "kitty":
		return LogosKitty
	}
	if getenv("NO_COLOR") != "" || getenv("TMUX") != "" || strings.HasPrefix(getenv("TERM"), "screen") {
		return LogosText
	}
	term, prog := strings.ToLower(getenv("TERM")), strings.ToLower(getenv("TERM_PROGRAM"))
	if term == "xterm-kitty" || getenv("KITTY_WINDOW_ID") != "" || term == "xterm-ghostty" || prog == "ghostty" {
		return LogosKitty
	}
	return LogosText
}

// logoBase is the first image id. Ids are 24-bit (they are sent as a
// truecolor foreground), and this range keeps clear of small ids other
// programs tend to use.
const logoBase = 0xAF4B00

// Logos is the set of images sent to the terminal: logo name → image id.
type Logos map[string]uint32

// logoNames are the embedded logos, in a fixed order so ids are stable.
func logoNames() []string {
	ents, _ := logoFS.ReadDir("logos")
	var out []string
	for _, e := range ents {
		if n, ok := strings.CutSuffix(e.Name(), ".png"); ok {
			out = append(out, n)
		}
	}
	return out
}

// SendLogos writes every logo to the terminal as a kitty image with a
// virtual placement 2 cells wide and 1 row high, and returns their ids.
func SendLogos(w io.Writer) (Logos, error) {
	ids := Logos{}
	for i, name := range logoNames() {
		png, err := logoFS.ReadFile("logos/" + name + ".png")
		if err != nil {
			return nil, err
		}
		id := uint32(logoBase + i)
		if _, err := io.WriteString(w, kittyImage(id, png)); err != nil {
			return nil, err
		}
		ids[name] = id
	}
	return ids, nil
}

// kittyImage is the escape sequence that sends png as image id with a
// 2×1-cell virtual placement, in chunks of at most 4096 bytes.
func kittyImage(id uint32, png []byte) string {
	data := base64.StdEncoding.EncodeToString(png)
	var b strings.Builder
	first := true
	for len(data) > 0 {
		n := min(len(data), 4096)
		chunk := data[:n]
		data = data[n:]
		more := 0
		if len(data) > 0 {
			more = 1
		}
		if first {
			fmt.Fprintf(&b, "\x1b_Ga=T,U=1,f=100,t=d,i=%d,c=2,r=1,q=2,m=%d;%s\x1b\\", id, more, chunk)
			first = false
		} else {
			fmt.Fprintf(&b, "\x1b_Gm=%d;%s\x1b\\", more, chunk)
		}
	}
	return b.String()
}

// The placeholder cell and the diacritics for row 0 and columns 0 and 1.
const (
	placeholder = "\U0010EEEE"
	diac0       = "̅"
	diac1       = "̍"
)

// placeholderCells is the 2-cell placement of an image.
const placeholderCells = placeholder + diac0 + diac0 + placeholder + diac0 + diac1

// logoName is the embedded logo for a route, or "" for none.
func (t Theme) logoName(r engine.Route) string {
	if r.IsGateway() {
		return "" // which gateway it is comes with gateway names in the engine
	}
	switch r.Harness {
	case "claude", "codex", "vllm", "copilot", "agy", "devin":
		return r.Harness
	case "grok", "ollama":
		if t.Dark {
			return r.Harness + "-light"
		}
		return r.Harness + "-dark"
	}
	return ""
}

// logo is a route's 2-cell logo: the image when the terminal shows them,
// else the text tag.
func (t Theme) logo(r engine.Route) seg {
	if id, ok := t.logos[t.logoName(r)]; ok {
		return sg(lipgloss.NewStyle().Foreground(lipgloss.Color(fmt.Sprintf("#%06x", id))), placeholderCells)
	}
	b := badge(r)
	return sg(t.Badge(b), b)
}

// WithLogos returns the theme drawing these images.
func (t Theme) WithLogos(l Logos) Theme {
	t.logos = l
	return t
}
