package main

import (
	"errors"
	"testing"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/tui"
)

// A cancelled card from the composer goes back to the composer; afk ends
// only when asked to, or when it was started with a prompt and that
// prompt's card is cancelled.
func TestAfterCard(t *testing.T) {
	for _, c := range []struct {
		name     string
		dec      tui.Decision
		composer bool
		sessions int
		done     bool
		code     int
	}{
		{"launch", tui.Decision{Launch: true}, true, 0, false, 0},
		{"run here", tui.Decision{RunHere: true}, true, 0, false, 0},
		{"card cancelled from the composer", tui.Decision{Cancelled: true}, true, 0, false, 0},
		{"card cancelled for afk \"prompt\"", tui.Decision{Cancelled: true}, false, 0, true, 130},
		{"exit before any session", tui.Decision{Cancelled: true, Exit: true}, true, 0, true, 130},
		{"exit after a session", tui.Decision{Cancelled: true, Exit: true}, true, 2, true, 0},
		{"engine failure", tui.Decision{Err: errors.New("x")}, true, 1, true, 4},
	} {
		_, done, code := afterCard(c.dec, c.composer, c.sessions, 0)
		if done != c.done || code != c.code {
			t.Errorf("%s: done %v code %d, want %v %d", c.name, done, code, c.done, c.code)
		}
	}
	if n := resumeNote(engine.Route{Harness: "claude"}, 130); n != "back in AFK · claude session ended (exit 130)" {
		t.Error(n)
	}
}
