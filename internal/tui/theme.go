package tui

import (
	"image/color"
	"os"
	"strings"

	"charm.land/lipgloss/v2"
)

// adaptive is a colour with a light-terminal variant. Lip Gloss v2 moved
// AdaptiveColor to its compat package, which queries the terminal when the
// package loads; that would also happen on the non-interactive paths that
// hand straight over to the engine. So the choice is made here instead,
// from the background colour Bubble Tea reports.
type adaptive struct{ light, dark string }

func (a adaptive) pick(dark bool) color.Color {
	if dark {
		return lipgloss.Color(a.dark)
	}
	return lipgloss.Color(a.light)
}

// The palette (one accent; the rest is semantic).
var (
	cAccent = adaptive{"#2f5fd0", "#7aa7ff"}
	cOK     = adaptive{"#1f8a4c", "#6cc58e"}
	cWarn   = adaptive{"#946200", "#e6b450"}
	cBad    = adaptive{"#c42b28", "#ef6f6c"}
	cDim    = adaptive{"#5f6672", "#7d8594"}
	cBorder = adaptive{"#a3a9b3", "#59616f"}
	cSelBG  = adaptive{"#e3e8f1", "#1f2633"}
)

// Brand colours of the 2-cell text badges.
var badgeColor = map[string]adaptive{
	"CL": {"#c15f3c", "#d97757"},
	"CX": {"#3d6fd6", "#8fb4ff"},
	"GK": {"#2b2b31", "#ececf1"},
	"GW": {"#4f5fd0", "#8fa2ff"},
	"VL": {"#a86f00", "#fdb515"},
	"OL": {"#2b2b31", "#ececf1"},
	"AG": {"#2a64c9", "#7fa8f5"},
	"OC": {"#2b2b31", "#ececf1"},
	"PI": {"#7a4fc4", "#b99cf2"},
	"DV": {"#167d6b", "#5cc9b4"},
	"CP": {"#3b3f46", "#d0d4da"},
}

// Theme is the resolved styles for one terminal.
type Theme struct {
	Dark                               bool
	Accent, OK, Warn, Bad, Dim, Border lipgloss.Style
	Bold, Key, Plain, SelBG, YoloTag   lipgloss.Style
	accent, ok, warn, bad, dim, border color.Color
	selbg                              color.Color
	badges                             map[string]color.Color
	logos                              Logos
}

// NewTheme resolves the palette for a dark or light background.
func NewTheme(dark bool) Theme {
	t := Theme{Dark: dark}
	t.accent, t.ok, t.warn, t.bad = cAccent.pick(dark), cOK.pick(dark), cWarn.pick(dark), cBad.pick(dark)
	t.dim, t.border, t.selbg = cDim.pick(dark), cBorder.pick(dark), cSelBG.pick(dark)
	s := lipgloss.NewStyle()
	t.Plain = s
	t.Accent = s.Foreground(t.accent)
	t.OK = s.Foreground(t.ok)
	t.Warn = s.Foreground(t.warn)
	t.Bad = s.Foreground(t.bad)
	t.Dim = s.Foreground(t.dim)
	t.Border = s.Foreground(t.border)
	t.Bold = s.Bold(true)
	t.Key = s.Foreground(t.accent)
	t.SelBG = s.Background(t.selbg)
	t.YoloTag = s.Bold(true).Foreground(lipgloss.Color("#ffffff")).Background(t.bad)
	t.badges = map[string]color.Color{}
	for k, v := range badgeColor {
		t.badges[k] = v.pick(dark)
	}
	return t
}

// Badge is the style of a 2-letter logo cell.
func (t Theme) Badge(code string) lipgloss.Style {
	if c, ok := t.badges[code]; ok {
		return lipgloss.NewStyle().Foreground(c)
	}
	return t.Plain
}

// MotionOff reports whether animation is turned off: NO_COLOR, TERM=dumb or
// AFK_MOTION=off. (Without a terminal afk never draws at all.)
func MotionOff(getenv func(string) string) bool {
	if getenv == nil {
		getenv = os.Getenv
	}
	return getenv("NO_COLOR") != "" ||
		strings.EqualFold(getenv("TERM"), "dumb") ||
		strings.EqualFold(getenv("AFK_MOTION"), "off")
}

// FPS is the redraw rate: 30, or 10 over SSH.
func FPS(getenv func(string) string) int {
	if getenv == nil {
		getenv = os.Getenv
	}
	if getenv("SSH_CONNECTION") != "" || getenv("SSH_TTY") != "" {
		return 10
	}
	return 30
}
