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
// renderer needs no special handling. Inside tmux the images go through
// tmux's passthrough. Terminals without placeholders get a pixel mark cut
// from the same image (logo_pixel.go), and NO_COLOR gets the 2-letter tag.

//go:embed logos/*.png
var logoFS embed.FS

// LogoMode is how route logos are drawn.
type LogoMode string

const (
	LogosText      LogoMode = "text"       // 2-letter tags in brand colours
	LogosPixel     LogoMode = "pixel"      // 2-cell quadrant-block marks
	LogosKitty     LogoMode = "kitty"      // images through kitty Unicode placeholders
	LogosKittyTmux LogoMode = "kitty-tmux" // the same, inside tmux, if tmux lets them through
)

// DetectLogos picks the logo mode from the environment. kitty and Ghostty
// show images; inside tmux they still can, if tmux passes them through
// (SetupLogos checks). Every other terminal gets pixel marks, and NO_COLOR
// gets text. AFK_LOGOS=text, pixel, kitty, iterm or sixel overrides it.
func DetectLogos(getenv func(string) string) LogoMode {
	switch strings.ToLower(getenv("AFK_LOGOS")) {
	case "text", "off":
		return LogosText
	case "pixel", "blocks", "iterm", "sixel":
		return LogosPixel // iterm and sixel draw over the marks (overlay.go)
	case "kitty":
		return LogosKitty
	}
	if getenv("NO_COLOR") != "" {
		return LogosText
	}
	term, prog := strings.ToLower(getenv("TERM")), strings.ToLower(getenv("TERM_PROGRAM"))
	tmux := getenv("TMUX") != ""
	// Under tmux, TERM and TERM_PROGRAM name tmux; the outer terminal shows
	// in the variables it set before tmux started.
	kitty := getenv("KITTY_WINDOW_ID") != "" || getenv("GHOSTTY_RESOURCES_DIR") != ""
	if !tmux {
		kitty = kitty || term == "xterm-kitty" || term == "xterm-ghostty" || prog == "ghostty"
	}
	switch {
	case kitty && tmux:
		return LogosKittyTmux
	case kitty:
		return LogosKitty
	}
	return LogosPixel
}

// SetupLogos gets the logos ready for the terminal on w and returns them,
// with a hint for the user when tmux is holding images back. In kitty
// mode it sends every image; inside tmux it first checks tmux passes them
// through and keeps 24-bit colour (the image id is the cells' colour).
func SetupLogos(w io.Writer, getenv func(string) string, tmuxShow func(format string) string) (Logos, string) {
	switch DetectLogos(getenv) {
	case LogosText:
		return nil, ""
	case LogosKitty:
		if l, err := SendLogos(w); err == nil {
			return l, ""
		}
	case LogosKittyTmux:
		if tmuxShow == nil {
			break
		}
		pass := tmuxShow("#{allow-passthrough}")
		if pass != "on" && pass != "all" {
			return PixelLogos(), "logos: run `tmux set -g allow-passthrough on` to see them as images"
		}
		if !strings.Contains(tmuxShow("#{client_termfeatures}"), "RGB") {
			return PixelLogos(), "logos: turn on 24-bit colour in tmux (set -as terminal-features ',*:RGB') to see them as images"
		}
		if l, err := sendLogos(w, tmuxWrap); err == nil {
			return l, ""
		}
	}
	return PixelLogos(), ""
}

// PixelLogos draws every logo as its pixel mark.
func PixelLogos() Logos {
	l := Logos{}
	for name := range pixelMarks() {
		l[name] = 0
	}
	return l
}

// tmuxWrap passes an escape sequence through tmux to the outer terminal:
// inside tmux's own DCS, with every ESC doubled.
func tmuxWrap(seq string) string {
	return "\x1bPtmux;" + strings.ReplaceAll(seq, "\x1b", "\x1b\x1b") + "\x1b\\"
}

// logoBase is the first image id. Ids are 24-bit (they are sent as a
// truecolor foreground), and this range keeps clear of small ids other
// programs tend to use.
const logoBase = 0xAF4B00

// Logos are the logos the terminal draws: logo name → the kitty image id
// sent for it, or 0 to draw its pixel mark. A logo not in the map, or a
// nil map, is drawn as its text tag.
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
func SendLogos(w io.Writer) (Logos, error) { return sendLogos(w, nil) }

func sendLogos(w io.Writer, wrap func(string) string) (Logos, error) {
	ids := Logos{}
	for i, name := range logoNames() {
		png, err := logoFS.ReadFile("logos/" + name + ".png")
		if err != nil {
			return nil, err
		}
		id := uint32(logoBase + i)
		seq := kittyImage(id, png)
		if wrap != nil {
			// Each chunk goes through on its own: tmux caps one passthrough.
			var b strings.Builder
			for _, part := range strings.SplitAfter(seq, "\x1b\\") {
				if part != "" {
					b.WriteString(wrap(part))
				}
			}
			seq = b.String()
		}
		if _, err := io.WriteString(w, seq); err != nil {
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
		return t.brandLogo(r.GatewayKind) // "" keeps the GW tag
	}
	switch r.Harness {
	case "claude", "codex", "vllm", "copilot", "agy", "devin", "kiro", "qwen", "gemini":
		return r.Harness
	case "grok", "ollama", "opencode", "pi", "cursor", "kimi":
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
	if r.IsLocal() {
		return t.engineLogo(r.Engine)
	}
	if s, ok := t.drawLogo(t.logoName(r)); ok {
		return s
	}
	b := badge(r)
	return sg(t.Badge(b), b)
}

// drawLogo is a named logo as the terminal draws it: placeholder cells
// for a kitty image, else its pixel mark.
func (t Theme) drawLogo(name string) (seg, bool) {
	id, ok := t.logos[name]
	switch {
	case !ok || name == "":
		return seg{}, false
	case id != 0:
		return sg(lipgloss.NewStyle().Foreground(lipgloss.Color(fmt.Sprintf("#%06x", id))), placeholderCells), true
	}
	m, ok := pixelMarks()[name]
	if !ok {
		return seg{}, false
	}
	return markSeg(m), true
}

// engineLogo is the logo of the engine serving a model.
func (t Theme) engineLogo(engine string) seg {
	if s, ok := t.drawLogo(t.brandLogo(engine)); ok {
		return s
	}
	code := engineCodes[engine]
	if code == "" {
		code = "LO"
	}
	return sg(t.Badge(code), code)
}

// brandLogos are the embedded logos of gateway kinds and local engines.
// A single-colour mark (mono) has a -light copy for dark terminals and a
// -dark copy for light ones. A kind left out is drawn as its text tag.
var brandLogos = map[string]struct {
	name string
	mono bool
}{
	// Gateways.
	"litellm":      {"litellm", false},
	"openrouter":   {"openrouter", true},
	"portkey":      {"portkey", false},
	"agentgateway": {"agentgateway", false},
	"envoy":        {"envoy", false},
	"kong":         {"kong", true},
	"cloudflare":   {"cloudflare", false},
	"vercel":       {"vercel", true},
	"openai":       {"openai", true},
	"anthropic":    {"anthropic", true},
	// Engines, which can also be a gateway's kind.
	"vllm":     {"vllm", false},
	"ollama":   {"ollama", true},
	"llamacpp": {"llamacpp", true},
	"lmstudio": {"lmstudio", true},
	"sglang":   {"sglang", false},
	"tgi":      {"tgi", false},
	"localai":  {"localai", false},
	"mlx":      {"mlx", true},
}

// brandLogo is the embedded logo of a gateway kind or engine for this
// terminal's background, or "" for none.
func (t Theme) brandLogo(kind string) string {
	b, ok := brandLogos[kind]
	switch {
	case !ok:
		return ""
	case !b.mono:
		return b.name
	case t.Dark:
		return b.name + "-light"
	}
	return b.name + "-dark"
}

var engineCodes = map[string]string{"vllm": "VL", "ollama": "OL", "llamacpp": "LC", "lmstudio": "LM", "sglang": "SG", "tgi": "TG", "localai": "LA", "mlx": "MX"}

// engineName is how an engine is written.
func engineName(e string) string {
	if n, ok := map[string]string{"vllm": "vLLM", "ollama": "Ollama", "llamacpp": "llama.cpp", "lmstudio": "LM Studio",
		"sglang": "SGLang", "tgi": "TGI", "localai": "LocalAI", "mlx": "MLX"}[e]; ok {
		return n
	}
	return e
}

// engineHost is where the engine runs: the label from config, else the
// gateway's host.
func engineHost(r engine.Route) string {
	if r.EngineHost != "" {
		return r.EngineHost
	}
	return gatewayHost(r)
}

// WithLogos returns the theme drawing these images.
func (t Theme) WithLogos(l Logos) Theme {
	t.logos = l
	return t
}
