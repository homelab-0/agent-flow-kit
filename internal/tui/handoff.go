package tui

import (
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// Esc's part in the handoff: it has walked off with the task by the time
// the CLI starts (an empty hammock is printed, so nothing delays the CLI),
// and it shuffles back with the receipt while AFK reads pool usage and git.

const (
	sceneWidth   = 74 // cells of the handoff strip
	sceneHome    = 26 // where Esc stops in front of the hammock
	backStepEach = 34 * time.Millisecond
	backStep     = 240 * time.Millisecond  // walk frame
	backHome     = 2200 * time.Millisecond // hops into the hammock
	backDoze     = 2700 * time.Millisecond // eyes close, z starts
	backZEach    = 350 * time.Millisecond
)

// sceneFits reports whether the handoff strip fits the terminal.
func sceneFits(width int) bool { return width <= 0 || width >= sceneWidth+2 }

// HandoffText is printed as the CLI takes the terminal: the empty
// hammock and "Esc is afk." (just the line without art or room).
func (t Theme) HandoffText(r engine.Route, art bool, width int) string {
	var out []line
	if art && sceneFits(width) {
		for _, row := range t.escLines(Scene(sceneWidth, Pose{X: sceneWidth}, false)) {
			out = append(out, append(line{sg(t.Plain, " ")}, row...))
		}
		out = append(out, nil)
	}
	out = append(out, line{sg(t.Plain, "  "), sg(t.Bold, "Esc is afk."), sg(t.Dim, "  "+routeName(r)+" has the terminal.")})
	return join(out)
}

type backMsg struct{}

func backTick(fps int) tea.Cmd {
	return tea.Tick(time.Second/time.Duration(max(fps, 1)), func(time.Time) tea.Msg { return backMsg{} })
}

// WithEsc has Esc walk back in above the receipt (art and room for the
// strip; with motion off it is already home).
func (m *RatingModel) WithEsc(art bool, width int, now func() time.Time) *RatingModel {
	m.art = art && sceneFits(width)
	if now != nil {
		m.now = now
	}
	return m
}

func (m *RatingModel) clock() time.Time {
	if m.now == nil {
		return time.Now()
	}
	return m.now()
}

// home reports whether Esc is back in the hammock (or not drawn at all).
func (m *RatingModel) home() bool {
	return !m.art || !m.motion || m.skipped || m.clock().Sub(m.backStart) >= backHome
}

// escBack is the strip above the receipt and Esc's line under it.
func (m *RatingModel) escBack() ([]line, line) {
	t := m.theme
	el := m.clock().Sub(m.backStart)
	if !m.motion || m.skipped {
		el = backDoze + 3*backZEach
	}
	var rows [][]escCell
	var say line
	switch {
	case el < backHome:
		x := max(sceneHome, sceneWidth-int(el/backStepEach))
		p := Pose{X: x, Eyes: "happy", Mouth: "smile"}
		say = line{sg(t.Plain, "  "), sg(t.Bold, "Esc is back."), sg(t.Dim, "  Here’s what happened.")}
		if x > sceneHome {
			step := (el / backStep) % 2
			p = Pose{X: x, Eyes: "left", Legs: "b", Bob: step == 1}
			if step == 1 {
				p.Legs = "a"
			}
			say = line{sg(t.Plain, "  "), sg(t.Bold, "Esc is back."), sg(t.Dim, "  Shuffling home with the receipt…")}
		}
		rows = Scene(sceneWidth, p, false)
	case el < backDoze:
		rows = Scene(sceneWidth, Pose{Eyes: "happy"}, true)
	default:
		rows = Scene(sceneWidth, Pose{Eyes: "closed", Z: min(3, int((el-backDoze)/backZEach))}, true)
	}
	var out []line
	for _, r := range t.escLines(rows) {
		out = append(out, append(line{sg(t.Plain, " ")}, r...))
	}
	return append(out, nil), say
}
