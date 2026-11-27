package tui

import (
	"strings"
	"testing"

	tea "charm.land/bubbletea/v2"
)

type altModel struct{ alt bool }

func (m altModel) Init() tea.Cmd { return nil }
func (m altModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if k, ok := msg.(tea.KeyPressMsg); ok {
		m.alt = k.String() == "a"
	}
	return m, nil
}
func (m altModel) View() tea.View { v := tea.NewView("x"); v.AltScreen = m.alt; return v }

func TestWithKittyLogos(t *testing.T) {
	if _, ok := WithKittyLogos(altModel{}, PixelLogos()).(altModel); !ok {
		t.Error("wrapped a program without kitty images")
	}
	m := WithKittyLogos(altModel{}, Logos{"claude": logoBase}).(*kittyAltModel)
	m.Update(tea.KeyPressMsg{Code: 'm', Text: "m"})
	if m.queue {
		t.Fatal("sent on the main screen")
	}
	if m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"}); !m.queue {
		t.Fatal("no send on entering the alternate screen")
	}
	if _, cmd := m.Update(kittyAltSend{}); cmd == nil || !m.sent {
		t.Fatal("the send did nothing")
	}
	if m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"}); m.queue {
		t.Error("sent twice on one visit")
	}
	// Back to the main screen and in again: sent again.
	m.Update(tea.KeyPressMsg{Code: 'm', Text: "m"})
	if m.Update(tea.KeyPressMsg{Code: 'a', Text: "a"}); !m.queue {
		t.Error("no send on the second visit")
	}
	seq, err := kittyLogoSeq()
	if err != nil || !strings.Contains(seq, "\x1b_Ga=T,U=1") {
		t.Errorf("logo sequence: %v", err)
	}
}
