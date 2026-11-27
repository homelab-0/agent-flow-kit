package tui

import (
	"context"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"

	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// RunModel is a turn running inside AFK: the notes so far (a failover, a
// stricter permission mode) and a line saying which route is working and
// for how long. esc or ctrl+c stops the turn, never AFK. Its last frame is
// empty: the caller prints what the turn left behind.
type RunModel struct {
	theme  Theme
	motion bool
	now    func() time.Time
	work   func(ctx context.Context, ev func(RunEvent))

	ctx     context.Context
	cancel  context.CancelFunc
	events  chan RunEvent
	started time.Time
	spin    int
	label   string
	notes   []string
	done    bool
	// Stopped: the person stopped the turn.
	Stopped bool
}

// RunEvent is news from a running turn: a note for the person, or the
// route now at work.
type RunEvent struct {
	Note  string
	Label string
}

type (
	runEventMsg struct {
		ev RunEvent
		ok bool
	}
	runDoneMsg struct{}
)

// NewRun builds the program for one turn. work runs the turn and reports
// through ev; it must return soon after ctx is cancelled.
func NewRun(dark, motion bool, work func(ctx context.Context, ev func(RunEvent))) *RunModel {
	ctx, cancel := context.WithCancel(context.Background())
	return &RunModel{theme: NewTheme(dark), motion: motion, now: time.Now, work: work,
		ctx: ctx, cancel: cancel, events: make(chan RunEvent, 64)}
}

// Notes are the notes the turn gave, in order.
func (m *RunModel) Notes() []string { return m.notes }

func (m *RunModel) Init() tea.Cmd {
	m.started = m.now()
	work, ctx, ch := m.work, m.ctx, m.events
	run := func() tea.Msg {
		work(ctx, func(e RunEvent) {
			select {
			case ch <- e:
			default: // a full buffer drops the note, never blocks the turn
			}
		})
		close(ch)
		return nil
	}
	cmds := []tea.Cmd{run, m.listen(), tea.RequestBackgroundColor}
	if m.motion {
		cmds = append(cmds, spinTick())
	}
	return tea.Batch(cmds...)
}

func (m *RunModel) listen() tea.Cmd {
	ch := m.events
	return func() tea.Msg {
		e, ok := <-ch
		if !ok {
			return runDoneMsg{}
		}
		return runEventMsg{e, true}
	}
}

func (m *RunModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.BackgroundColorMsg:
		m.theme = NewTheme(msg.IsDark())
	case spinMsg:
		m.spin++
		if !m.done {
			return m, spinTick()
		}
	case runEventMsg:
		if n := strings.TrimSpace(msg.ev.Note); n != "" {
			m.notes = append(m.notes, n)
		}
		if msg.ev.Label != "" {
			m.label = msg.ev.Label
		}
		return m, m.listen()
	case runDoneMsg:
		m.done = true
		m.cancel()
		return m, tea.Quit
	case tea.KeyPressMsg:
		switch msg.String() {
		case "esc", "ctrl+c":
			// Stop the turn; the program ends when the work returns.
			m.Stopped = true
			m.cancel()
		}
	}
	return m, nil
}

func (m *RunModel) View() tea.View { return tea.NewView(m.Render()) }

// Render is the running frame; empty once the turn is over.
func (m *RunModel) Render() string {
	if m.done {
		return ""
	}
	t := m.theme
	var out []line
	for _, n := range m.notes {
		out = append(out, line{sg(t.Dim, "  "+n)})
	}
	glyph := "·"
	if m.motion {
		glyph = spinFrames[m.spin%len(spinFrames)]
	}
	what, detail := "Routing", ""
	if m.label != "" {
		what, detail = "Running", m.label
	}
	if m.Stopped {
		what = "Stopping"
	}
	l := line{sg(t.Accent, " "+glyph+" "), sg(t.Bold, what)}
	if detail != "" {
		l = append(l, sg(t.Dim, "  "+detail))
	}
	l = append(l, sg(t.Dim, " · "+duration(m.now().Sub(m.started))))
	if !m.Stopped {
		l = append(l, sg(t.Dim, "   "), sg(t.Key, "esc"), sg(t.Dim, " stop"))
	}
	return join(append(out, l))
}

// PromptText is a sent prompt as the transcript shows it.
func (t Theme) PromptText(prompt string, width int) string {
	return t.promptLine(prompt, width).render()
}

// NoteText is a dim line in the transcript.
func (t Theme) NoteText(s string) string { return line{sg(t.Dim, "  "+s)}.render() }

// WarnText is a warning line in the transcript.
func (t Theme) WarnText(s string) string { return line{sg(t.Warn, "  "+s)}.render() }

// ReceiptText is the receipt line of a turn.
func (t Theme) ReceiptText(r Receipt) string { return t.ReceiptLine(r).render() }

// RouteLabel is a route in a few words: "codex / gpt-6.1-sol · medium".
func RouteLabel(r engine.Route) string {
	s := routeName(r)
	if r.Model != "" {
		s += " / " + r.Model
	}
	if r.Effort != "" {
		s += " · " + r.Effort
	}
	return s
}

// CleanOutput makes a CLI's answer safe to print: control characters other
// than newline and tab are dropped, so an answer can't drive the terminal.
func CleanOutput(s string) string {
	return strings.Map(func(r rune) rune {
		switch {
		case r == '\n' || r == '\t':
			return r
		case r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0):
			return -1
		}
		return r
	}, strings.ReplaceAll(s, "\r\n", "\n"))
}
