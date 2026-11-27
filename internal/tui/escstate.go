package tui

import "time"

// Timings of Esc in the header (see the mascot spec).
const (
	escYawnUntil    = 450 * time.Millisecond // still in the hammock: "*yawn* fine, getting up…"
	escStretchUntil = 800 * time.Millisecond // standing, eyes closed, mouth open
	escGlance       = 520 * time.Millisecond // eyes left and right while routing
	escStandX       = 7                      // standing Esc's column in the header
)

// escState is Esc's pose and status line for the card's current state.
func (m *Model) escState() (Pose, line) {
	t := m.theme
	stand := Pose{Stand: true, X: escStandX, Eyes: "lidded"}
	switch m.st {
	case sIntro:
		return m.introPose()
	case sCompose:
		return m.composePose()
	case sRouting:
		if !m.opt.Motion {
			return stand, line{sg(t.Dim, "Esc is checking the options")}
		}
		el := m.opt.Now().Sub(m.started)
		switch {
		case el < escYawnUntil:
			return Pose{Eyes: "lidded"}, line{sg(t.Dim, "*yawn* fine, getting up…")}
		case el < escStretchUntil:
			return Pose{Stand: true, X: escStandX, Eyes: "closed", Mouth: "o"}, line{sg(t.Dim, "*stretch*")}
		}
		p := stand
		if el >= 700*time.Millisecond {
			p.Eyes = "right"
			if (el/escGlance)%2 == 1 {
				p.Eyes = "left"
			}
		}
		return p, line{sg(t.Accent, spinFrames[m.spin%len(spinFrames)]+" "), sg(t.Dim, "Esc is checking the options")}
	case sError:
		return Pose{Stand: true, X: escStandX, Eyes: "wide"}, line{sg(t.Warn, "Esc needs you."), sg(t.Dim, " Something is in the way.")}
	case sLaunching:
		if len(m.card.Rows) > 0 {
			return stand, line{sg(t.Dim, "*yawn* okay okay, I’m going…")}
		}
		return stand, line{sg(t.Dim, "Esc is checking the options")}
	case sDone:
		if m.dec.Cancelled {
			return Pose{Eyes: "closed", Z: 3}, line{sg(t.Dim, "Esc went back to sleep.")}
		}
	}
	if len(m.card.Rows) == 0 {
		return stand, line{sg(t.Dim, "Esc is checking the options")}
	}
	// On the card Esc suggests the router's pick, and glances at whatever
	// row you move to.
	if m.card.Sel != m.pick {
		stand.Eyes = "right"
		if m.card.Sel%2 == 1 {
			stand.Eyes = "left"
		}
	}
	pick := m.card.Rows[min(max(m.pick, 0), len(m.card.Rows)-1)]
	return stand, line{sg(t.Dim, "Esc suggests "), sg(t.Plain, routeName(pick)), sg(t.Dim, ". Can I sit down now?")}
}
