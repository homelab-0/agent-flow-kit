package tui

import (
	"os"
	"path/filepath"
	"strings"
)

// Header is what the header card says about this session: AFK's version,
// the folder and the git branch.
type Header struct {
	Version string // shown as v<Version>; "dev" for a local build
	Dir     string // the working folder, with the home folder as ~
	Branch  string // "" outside a git repository
	// Art draws Esc. Off with NO_COLOR or TERM=dumb, where the header is
	// text only.
	Art bool
}

// HomeDir shortens dir to ~/… when it is under home.
func HomeDir(dir, home string) string {
	if home == "" || dir == "" {
		return dir
	}
	if dir == home {
		return "~"
	}
	rel, err := filepath.Rel(home, dir)
	if err != nil || rel == "." || strings.HasPrefix(rel, "..") {
		return dir
	}
	return "~" + string(os.PathSeparator) + rel
}

func (h Header) versionText() string {
	v := strings.TrimPrefix(h.Version, "v")
	if v == "" {
		v = "dev"
	}
	if v == "dev" {
		return " dev · Agent Flow Kit"
	}
	return " v" + v + " · Agent Flow Kit"
}

func (h Header) placeText() string {
	if h.Branch == "" {
		return h.Dir
	}
	return h.Dir + " · " + h.Branch
}

// HeaderLines is the header card: Esc in the hammock on the left, then
// AFK's version, the folder and branch, and Esc's status line. Without
// art (NO_COLOR, TERM=dumb) it is the same box with the text only.
func (t Theme) HeaderLines(h Header, pose Pose, status line, width int) []line {
	w := boxW(width)
	tail := line{sg(t.Dim, "Type a task. Esc will get up. Eventually.")}
	text := []line{
		nil,
		{sg(t.Bold, "AFK"), sg(t.Dim, h.versionText())},
		{sg(t.Dim, h.placeText())},
		nil,
		status,
		tail,
	}
	out := []line{t.top("", w, t.Border)}
	if !h.Art {
		for _, l := range []line{text[1], text[2], text[4]} {
			out = append(out, t.boxLine(w, t.Border, l))
		}
		return append(out, t.bottom(w, t.Border))
	}
	art := t.escLines(Sprite(pose))
	for i := range art {
		l := append(line{sg(t.Plain, " ")}, art[i]...)
		l = append(l, sg(t.Plain, "   "))
		l = append(l, text[i]...)
		out = append(out, t.boxLine(w, t.Border, l))
	}
	return append(out, t.bottom(w, t.Border))
}
