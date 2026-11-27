package tui

import (
	"context"
	"strings"
	"testing"
	"time"

	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/x/ansi"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

func TestRunModelShowsTheTurnAndStops(t *testing.T) {
	release := make(chan struct{})
	var cancelled bool
	m := NewRun(true, false, func(ctx context.Context, ev func(RunEvent)) {
		ev(RunEvent{Note: "claude/opus failed (pool); trying codex / sol"})
		ev(RunEvent{Label: "codex / sol · medium"})
		select {
		case <-ctx.Done():
			cancelled = true
		case <-release:
		}
	})
	start := time.Unix(1795000000, 0)
	m.now = func() time.Time { return start.Add(12 * time.Second) }
	m.started = start
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "Routing") || !strings.Contains(s, "esc stop") {
		t.Errorf("before a route is known: %q", s)
	}
	m.Update(runEventMsg{RunEvent{Note: " a note "}, true})
	m.Update(runEventMsg{RunEvent{Label: "codex / sol · medium"}, true})
	s := ansi.Strip(m.Render())
	if !strings.Contains(s, "  a note") || !strings.Contains(s, "Running  codex / sol · medium · 12s") {
		t.Errorf("running: %q", s)
	}
	// esc stops the turn; the program ends only when the work returns.
	_, cmd := m.Update(tea.KeyPressMsg{Code: tea.KeyEscape})
	if !m.Stopped || cmd != nil || m.ctx.Err() == nil {
		t.Fatalf("esc: stopped %v", m.Stopped)
	}
	if s := ansi.Strip(m.Render()); !strings.Contains(s, "Stopping") || strings.Contains(s, "esc stop") {
		t.Errorf("stopping: %q", s)
	}
	_, cmd = m.Update(runDoneMsg{})
	if cmd == nil || m.Render() != "" || len(m.Notes()) != 1 {
		t.Errorf("done leaves nothing on screen and keeps the notes: %q %v", m.Render(), m.Notes())
	}
	close(release)
	_ = cancelled
}

func TestCleanOutputAndRouteLabel(t *testing.T) {
	if got := CleanOutput("ok\x1b[2Jgone\r\nnext\tcol\x07\u009b"); got != "ok[2Jgone\nnext\tcol" {
		t.Errorf("%q", got)
	}
	if got := RouteLabel(engine.Route{Harness: "codex", Model: "sol", Effort: "high"}); got != "codex / sol · high" {
		t.Error(got)
	}
}
