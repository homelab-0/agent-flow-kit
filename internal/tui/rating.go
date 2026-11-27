package tui

import (
	"fmt"
	"time"

	tea "charm.land/bubbletea/v2"
)

// RatingModel shows the receipt and asks for the rating. Fill computes the
// slow parts (pool usage after the session, git) while the line is up.
type RatingModel struct {
	theme   Theme
	rec     Receipt
	fill    func() Receipt
	ready   bool
	done    bool
	Outcome string // "" when skipped
	Save    func(outcome string) error
	saveErr error
	spin    int
	motion  bool

	// Esc walking back in (WithEsc).
	art       bool
	now       func() time.Time
	backStart time.Time
	skipped   bool // a key ended the walk
}

type receiptMsg struct{ r Receipt }

// NewRating builds the receipt program. fill may be nil when rec is final.
func NewRating(rec Receipt, fill func() Receipt, save func(string) error, dark, motion bool) *RatingModel {
	return &RatingModel{theme: NewTheme(dark), rec: rec, fill: fill, ready: fill == nil, Save: save, motion: motion}
}

func (m *RatingModel) Init() tea.Cmd {
	cmds := []tea.Cmd{tea.RequestBackgroundColor}
	m.backStart = m.clock()
	if m.art && m.motion {
		cmds = append(cmds, backTick(30))
	}
	if m.fill != nil {
		f := m.fill
		cmds = append(cmds, func() tea.Msg { return receiptMsg{f()} })
		if m.motion {
			cmds = append(cmds, spinTick())
		}
	}
	return tea.Batch(cmds...)
}

func (m *RatingModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.BackgroundColorMsg:
		m.theme = NewTheme(msg.IsDark())
	case spinMsg:
		m.spin++
		if !m.ready {
			return m, spinTick()
		}
	case backMsg:
		if m.clock().Sub(m.backStart) < backDoze+4*backZEach && !m.skipped && !m.done {
			return m, backTick(30)
		}
	case receiptMsg:
		m.rec, m.ready = msg.r, true
		if m.Save != nil {
			m.saveErr = m.Save("")
		}
	case tea.KeyPressMsg:
		if !m.home() {
			m.skipped = true // any key brings Esc home; the next one rates
			return m, nil
		}
		if !m.ready {
			return m, nil
		}
		k := msg.String()
		if o, ok := Ratings[k]; ok {
			m.Outcome = o
		} else if k != "enter" && k != "esc" && k != "ctrl+c" {
			return m, nil
		}
		if m.Save != nil {
			m.saveErr = m.Save(m.Outcome)
		}
		m.done = true
		return m, tea.Quit
	}
	return m, nil
}

func (m *RatingModel) View() tea.View { return tea.NewView(m.Render()) }

// Render is the receipt block.
func (m *RatingModel) Render() string {
	if !m.art {
		return m.receipt()
	}
	scene, say := m.escBack()
	if !m.home() {
		return join(append(scene, say))
	}
	return join(scene) + "\n" + m.receipt()
}

func (m *RatingModel) receipt() string {
	t := m.theme
	if !m.ready {
		g := "·"
		if m.motion {
			g = spinFrames[m.spin%len(spinFrames)]
		}
		return join([]line{{sg(t.Accent, "  "+g+" "), sg(t.Plain, fmt.Sprintf("%s exited %d", routeName(m.rec.Route), m.rec.ExitCode)), sg(t.Dim, " · "+duration(m.rec.Duration)+" · reading pool usage and git…")}})
	}
	lines := []line{t.ReceiptLine(m.rec), t.ratingLine()}
	if m.done {
		switch {
		case m.saveErr != nil:
			lines = append(lines, line{sg(t.Warn, "    Not saved: "), sg(t.Dim, m.saveErr.Error())})
		case m.Outcome == "":
			lines = append(lines, line{sg(t.Dim, "    Skipped. The run is saved without a rating.")})
		default:
			l := line{sg(t.OK, "    Saved.")}
			if m.art {
				l = append(l, sg(t.Dim, " Esc flopped back into the hammock."))
			}
			lines = append(lines, l)
		}
	}
	return join(lines)
}
