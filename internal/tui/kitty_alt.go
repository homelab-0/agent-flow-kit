package tui

import (
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
)

// kitty and Ghostty keep the main and the alternate screen's images
// apart: the logos SetupLogos sent before the program started are on the
// main screen only. WithKittyLogos sends them again each time the
// program's frame moves to the alternate screen, such as the control
// panel, so the placeholders there have images to show.
func WithKittyLogos(m tea.Model, l Logos) tea.Model {
	for _, id := range l {
		if id != 0 {
			return &kittyAltModel{inner: m}
		}
	}
	return m
}

type kittyAltModel struct {
	inner tea.Model
	sent  bool // the alternate screen has the images now
	queue bool // a send is scheduled
}

type kittyAltSend struct{}

func (m *kittyAltModel) Init() tea.Cmd { return m.inner.Init() }

func (m *kittyAltModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if _, ok := msg.(kittyAltSend); ok {
		m.sent, m.queue = true, false
		seq, err := kittyLogoSeq()
		if err != nil {
			return m, nil
		}
		return m, tea.Raw(seq)
	}
	var cmd tea.Cmd
	m.inner, cmd = m.inner.Update(msg)
	alt := m.inner.View().AltScreen
	if !alt {
		m.sent = false // leaving it drops its images
	}
	if alt && !m.sent && !m.queue {
		// Bubble Tea writes raw output before the frame that switches
		// screens, so the images go out on a later tick.
		m.queue = true
		cmd = tea.Batch(cmd, tea.Tick(60*time.Millisecond, func(time.Time) tea.Msg { return kittyAltSend{} }))
	}
	return m, cmd
}

func (m *kittyAltModel) View() tea.View { return m.inner.View() }

// kittyLogoSeq is every logo as kitty images, the same ids SendLogos uses.
func kittyLogoSeq() (string, error) {
	var b strings.Builder
	if _, err := sendLogos(&b, nil); err != nil {
		return "", err
	}
	return b.String(), nil
}
