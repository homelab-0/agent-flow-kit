package tui

import (
	"context"
	"fmt"
	"strings"
	"time"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
)

// The composer is what plain `afk` opens with: Esc's startup animation,
// then an input bar under the header, a status line with every route's
// headroom, and a hint line. ↵ routes the task and the card takes over.

// Startup animation timings (mascot spec).
const (
	introWalk     = 1300 * time.Millisecond // Esc walks in from the left
	introYawn     = 1750 * time.Millisecond
	introHop      = 1950 * time.Millisecond // then in the hammock, z starts
	introDone     = 2150 * time.Millisecond // the input bar appears
	introStepEach = 72 * time.Millisecond   // one column per step
	escStep       = 240 * time.Millisecond  // walk frame
	napZEvery     = 650 * time.Millisecond
	swayEvery     = 900 * time.Millisecond
	composeTick   = 130 * time.Millisecond
)

// taskKinds are what tab steps through in the composer.
var taskKinds = []string{"auto", "coding", "quick", "complex", "review", "architecture", "webdev", "research", "security"}

const composePlaceholder = "Describe a task. AFK routes it to the right CLI."

type (
	previewMsg struct{ ex *engine.Explain }
	escMsg     struct{}
)

func (m *Model) escTick(every time.Duration) tea.Cmd {
	return tea.Tick(every, func(time.Time) tea.Msg { return escMsg{} })
}

// composeInit starts the composer: the intro (with motion and room for
// the header) and a background route for the status line.
func (m *Model) composeInit() tea.Cmd {
	m.cin = textinput.New()
	m.cin.Prompt = ""
	m.cin.CharLimit = 4000
	m.introStart = m.opt.Now()
	m.st = sCompose
	cmds := []tea.Cmd{m.previewCmd(), m.poolsCmd(), tea.RequestBackgroundColor, m.cin.Focus()}
	if m.opt.Motion && m.opt.Header != nil && m.opt.Header.Art && !m.compact() {
		m.st = sIntro
		cmds = append(cmds, m.escTick(time.Second/time.Duration(m.opt.FPS)))
	} else if m.opt.Motion {
		cmds = append(cmds, m.escTick(composeTick))
	}
	return tea.Batch(cmds...)
}

func (m *Model) compact() bool { return m.width > 0 && m.width < compactBelow }

// previewCmd routes an empty task in the background, for the status
// line's routes and headroom. A failure just leaves the line without them.
func (m *Model) previewCmd() tea.Cmd {
	be, f, parent := m.be, m.opt.Flags, m.ctx
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(parent, explainTimeout)
		defer cancel()
		ex, err := be.Explain(ctx, f, "")
		if err != nil {
			return previewMsg{nil}
		}
		return previewMsg{ex}
	}
}

// onEscTick advances the intro and keeps Esc swaying in the composer.
func (m *Model) onEscTick() tea.Cmd {
	switch m.st {
	case sIntro:
		if m.opt.Now().Sub(m.introStart) >= introDone {
			m.st = sCompose
			return m.escTick(composeTick)
		}
		return m.escTick(time.Second / time.Duration(m.opt.FPS))
	case sCompose:
		if m.opt.Motion {
			return m.escTick(composeTick)
		}
	}
	return nil
}

// composeKey handles a key in the intro or the composer. Any key ends the
// intro, and the key itself still goes to the input.
func (m *Model) composeKey(k tea.KeyPressMsg) tea.Cmd {
	if m.st == sIntro {
		m.st = sCompose
	}
	key := k.String()
	m.notice = ""
	switch key {
	case "enter":
		return m.submit()
	case "tab":
		m.taskIdx = (m.taskIdx + 1) % len(taskKinds)
		return nil
	case "shift+tab":
		m.taskIdx = (m.taskIdx - 1 + len(taskKinds)) % len(taskKinds)
		return nil
	case "esc":
		if m.help {
			m.help = false
			return nil
		}
		if m.cin.Value() != "" {
			m.cin.SetValue("")
			return nil
		}
		return m.finish(Decision{Cancelled: true})
	case "?":
		if m.cin.Value() == "" {
			m.help = !m.help
			return nil
		}
	case "2", "3", "4", "5", "6", "7":
		if m.cin.Value() == "" && m.opt.Panel != nil {
			return m.openPanel(Tab(key[0] - '1'))
		}
	}
	m.help = false
	var cmd tea.Cmd
	m.cin, cmd = m.cin.Update(k)
	return cmd
}

// submit runs a slash command, or routes the task.
func (m *Model) submit() tea.Cmd {
	text := strings.TrimSpace(m.cin.Value())
	// /harness (one) pins a CLI; /harnesses opens its tab.
	if tab, ok := TabFor(text); ok && tab != TabRoute && strings.HasPrefix(text, "/") && text != "/harness" && m.opt.Panel != nil {
		m.cin.SetValue("")
		return m.openPanel(tab)
	}
	if strings.HasPrefix(text, "/") {
		m.notice = m.command(text)
		m.cin.SetValue("")
		return nil
	}
	if k := taskKinds[m.taskIdx]; k != "auto" {
		m.opt.Flags.Task = k
	}
	m.cin.Blur()
	m.card.Prompt = text
	return m.reroute()
}

// command applies a slash command and returns a notice for an unknown one.
func (m *Model) command(text string) string {
	name, arg, _ := strings.Cut(strings.TrimPrefix(text, "/"), " ")
	arg = strings.TrimSpace(arg)
	f := &m.opt.Flags
	var dst *string
	switch name {
	case "harness":
		dst = &f.Harness
	case "model":
		dst = &f.Model
	case "effort":
		dst = &f.Effort
	case "prefer":
		if arg != "" && arg != "balanced" && arg != "cheap" && arg != "best" {
			return "prefer is balanced, cheap or best"
		}
		dst = &f.Prefer
	case "clear":
		f.Harness, f.Model, f.Effort, f.Prefer = "", "", "", ""
		return ""
	default:
		s := "unknown command /" + name + ": try /harness, /model, /effort, /prefer, /clear"
		if m.opt.Panel != nil {
			s += ", or a tab: /harnesses /bench /skills /mcp /runs /config"
		}
		return s
	}
	*dst = arg // an empty argument unpins it
	return ""
}

// composeLines is the composer under the header: the input bar, the
// status line and the hint line (or the shortcuts).
func (m *Model) composeLines() []line {
	t, w := m.theme, boxW(m.width)
	out := []line{nil, m.inputBar(w), m.statusLine(w)}
	if m.help {
		for _, l := range []line{
			{sg(t.Key, "  ↵"), sg(t.Dim, " route the task (empty: open the CLI without one)")},
			{sg(t.Key, "  tab"), sg(t.Dim, " task kind: "+strings.Join(taskKinds, ", "))},
			{sg(t.Key, "  /harness /model /effort /prefer"), sg(t.Dim, " pin a choice  "), sg(t.Key, "/clear"), sg(t.Dim, " unpin")},
			{sg(t.Key, "  esc"), sg(t.Dim, " clear the input, or quit")},
		} {
			out = append(out, fitLine(l, w))
		}
		return out
	}
	hint := line{sg(t.Dim, "  "), sg(t.Key, "tab"), sg(t.Dim, " task · "), sg(t.Key, "/"), sg(t.Dim, " commands · "), sg(t.Key, "?"), sg(t.Dim, " for shortcuts")}
	out = append(out, hint)
	if m.notice != "" {
		out = append(out, fitLine(line{sg(t.Warn, "  "+m.notice)}, w))
	}
	return out
}

func (m *Model) inputBar(w int) line {
	t := m.theme
	bar := lipgloss.NewStyle().Background(t.inbar)
	val := m.cin.Value()
	l := line{sg(t.Accent, " › ")}
	if val == "" {
		l = append(l, sg(t.Accent, "▏"), sg(t.Dim, composePlaceholder))
	} else {
		pos := min(m.cin.Position(), len([]rune(val)))
		r := []rune(val)
		before, after := string(r[:pos]), string(r[pos:])
		// Keep the cursor in view: show the end of a long line.
		room := w - 5
		if lenCells(before)+1 > room {
			rb := []rune(before)
			for len(rb) > 0 && lenCells(string(rb))+2 > room {
				rb = rb[1:]
			}
			before = "…" + string(rb)
		}
		l = append(l, sg(t.Plain, before), sg(t.Accent, "▏"), sg(t.Plain, after))
	}
	return fitLine(l, w).pad(w, t.Plain).on(bar)
}

// statusLine is the prefer mode, the task kind, any pinned choices, and
// every route's logo with its headroom.
func (m *Model) statusLine(w int) line {
	t := m.theme
	f := m.opt.Flags
	prefer := f.Prefer
	if prefer == "" && m.preview != nil {
		prefer = m.preview.Prefer
	}
	if prefer == "" {
		prefer = "balanced"
	}
	l := line{sg(t.Dim, "  "+prefer+" · "), sg(t.Plain, taskKinds[m.taskIdx])}
	for _, p := range [][2]string{{"harness", f.Harness}, {"model", f.Model}, {"effort", f.Effort}} {
		if p[1] != "" {
			l = append(l, sg(t.Dim, " · "+p[0]+" "), sg(t.Accent, p[1]))
		}
	}
	l = append(l, sg(t.Plain, " "))
	if m.preview == nil {
		return fitLine(append(l, sg(t.Dim, " checking routes…")), w)
	}
	rows, _ := m.preview.Rows()
	for _, r := range rows {
		l = append(l, sg(t.Plain, " "), t.logo(r))
		switch {
		case r.PoolHeadroomPct != nil:
			l = append(l, sg(t.style(t.headroom(r.PoolHeadroomPct)), fmt.Sprintf(" %s", pctText(r.PoolHeadroomPct))))
		case r.CostClass == "free" || r.CostClass == "local":
			l = append(l, sg(t.OK, " free"))
		default:
			l = append(l, sg(t.Dim, " "+unknownText))
		}
		l = append(l, sg(t.Plain, " "))
	}
	return fitLine(l, w)
}

// introPose is Esc during the startup animation.
func (m *Model) introPose() (Pose, line) {
	t := m.theme
	el := m.opt.Now().Sub(m.introStart)
	switch {
	case el < introWalk:
		step := (el / escStep) % 2
		p := Pose{Stand: true, X: -12 + int(el/introStepEach), Eyes: "right", Legs: "b", Bob: step == 1}
		if step == 1 {
			p.Legs = "a"
		}
		return p, line{sg(t.Dim, "Esc is heading to the hammock…")}
	case el < introYawn:
		return Pose{Stand: true, X: 6, Eyes: "closed", Mouth: "o"}, line{sg(t.Dim, "*yawn*")}
	case el < introHop:
		return Pose{Stand: true, X: 6, Eyes: "lidded", Hop: true}, line{sg(t.Dim, "*hup*")}
	}
	return Pose{Eyes: "closed", Z: min(3, int((el-introHop)/(250*time.Millisecond)))}, line{sg(t.Dim, "Esc is chilling")}
}

// composePose is Esc in the hammock while you type: asleep and swaying,
// or one eye open once there is text.
func (m *Model) composePose() (Pose, line) {
	t := m.theme
	if m.cin.Value() != "" {
		return Pose{Eyes: "peek"}, line{sg(t.Dim, "Esc opened one eye…")}
	}
	p := Pose{Eyes: "closed", Z: 3}
	if m.opt.Motion {
		now := m.opt.Now().Sub(m.introStart)
		p.Sway = int((now / swayEvery) % 2)
		p.Z = int((now / napZEvery) % 4)
		if now >= introHop && now < introHop+750*time.Millisecond {
			p.Z = min(3, int((now-introHop)/(250*time.Millisecond))) // the intro's z keeps counting up
		}
	}
	return p, line{sg(t.Dim, "Esc is chilling")}
}
