package tui

import (
	"time"

	tea "charm.land/bubbletea/v2"
)

// The braille spinner: 80ms a frame.
const spinEvery = 80 * time.Millisecond

var spinFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

type spinMsg struct{}

func spinTick() tea.Cmd {
	return tea.Tick(spinEvery, func(time.Time) tea.Msg { return spinMsg{} })
}
