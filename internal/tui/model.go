package tui

import (
	"context"
	"errors"
	"os"
	"strings"
	"time"

	"charm.land/bubbles/v2/textinput"
	tea "charm.land/bubbletea/v2"
	"github.com/charmbracelet/harmonica"
	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
	"github.com/jlengelbrecht/agent-flow-kit/internal/launch"
)

// Backend is the engine as the card sees it.
type Backend interface {
	Explain(ctx context.Context, f engine.RouteFlags, prompt string) (*engine.Explain, error)
	LaunchPlan(ctx context.Context, r engine.Route, mode string, perm string, pass []string, prompt string) (*engine.LaunchPlan, error)
	Pools(ctx context.Context) (*engine.Pools, error)
}

// Options configure the card.
type Options struct {
	Flags  engine.RouteFlags
	Prompt string
	Pass   []string
	Yolo   bool // --yolo was given
	// YoloBlock, when set, is why yolo can't be turned on here (this
	// directory isn't trusted); y shows it instead.
	YoloBlock string
	Yes       bool // --yes: launch the router's choice without the card
	Width     int
	Motion    bool
	FPS       int
	Dark      bool
	// Environ is the environment the launch is checked against (os.Environ
	// when nil).
	Environ []string
	Now     func() time.Time
	Loc     *time.Location
}

// Decision is how the card ended.
type Decision struct {
	Launch    bool
	Route     engine.Route
	Plan      *engine.LaunchPlan
	Yolo      bool
	Prompt    string
	Pools     *engine.Pools // pool usage when the card opened (nil if unknown)
	Cancelled bool
	Err       error // the engine failed; nothing to launch
}

type state int

const (
	sRouting state = iota
	sCard
	sWhy
	sEdit
	sLaunching
	sError
	sDone
)

// Meter fill: a critically damped spring that settles in about 650ms.
const (
	fillDuration = 650 * time.Millisecond
	springFreq   = 11.0
	routingDelay = 150 * time.Millisecond

	// Engine calls are bounded; a hung engine is stopped.
	explainTimeout = 60 * time.Second
	planTimeout    = 20 * time.Second
	poolsTimeout   = 30 * time.Second
)

type (
	explainMsg struct {
		ex  *engine.Explain
		err error
	}
	poolsMsg struct{ p *engine.Pools }
	planMsg  struct {
		plan *engine.LaunchPlan
		err  error
	}
	animMsg struct{ gen int }
)

// Model is the route card program.
type Model struct {
	opt   Options
	be    Backend
	theme Theme
	width int
	st    state
	card  Card

	started  time.Time
	spin     int
	spring   harmonica.Spring
	pos, vel float64
	frames   int
	animGen  int

	yoloArmed bool
	notice    string
	errText   string
	nextBest  int
	input     textinput.Model
	yoloSet   bool // y has set the yolo toggle

	dec Decision

	ctx      context.Context // cancelled when the card ends
	cancel   context.CancelFunc
	routeErr bool // the error dialog is about routing, not a launch
}

// New builds the card model.
func New(be Backend, opt Options) *Model {
	if opt.FPS <= 0 {
		opt.FPS = 30
	}
	if opt.Now == nil {
		opt.Now = time.Now
	}
	m := &Model{opt: opt, be: be, theme: NewTheme(opt.Dark), width: opt.Width}
	m.ctx, m.cancel = context.WithCancel(context.Background())
	m.spring = harmonica.NewSpring(harmonica.FPS(opt.FPS), springFreq, 1.0)
	m.card = Card{Prompt: opt.Prompt, Yolo: opt.Yolo, Efforts: map[int]string{}, Loc: opt.Loc}
	in := textinput.New()
	in.Prompt = ""
	in.CharLimit = 4000
	m.input = in
	return m
}

// Close stops any engine call still running.
func (m *Model) Close() { m.cancel() }

// Decision is the outcome once the program has finished.
func (m *Model) Decision() Decision { return m.dec }

func (m *Model) Init() tea.Cmd {
	m.started = m.opt.Now()
	cmds := []tea.Cmd{m.explainCmd(), m.poolsCmd(), tea.RequestBackgroundColor}
	if m.opt.Motion {
		cmds = append(cmds, spinTick())
	}
	return tea.Batch(cmds...)
}

func (m *Model) explainCmd() tea.Cmd {
	be, f, p, parent := m.be, m.opt.Flags, m.card.Prompt, m.ctx
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(parent, explainTimeout)
		defer cancel()
		ex, err := be.Explain(ctx, f, p)
		return explainMsg{ex, err}
	}
}

func (m *Model) poolsCmd() tea.Cmd {
	be, parent := m.be, m.ctx
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(parent, poolsTimeout)
		defer cancel()
		p, err := be.Pools(ctx)
		if err != nil {
			return poolsMsg{nil}
		}
		return poolsMsg{p}
	}
}

func (m *Model) planCmd() tea.Cmd {
	perm := m.card.LaunchMode()
	be, r, pass, p, parent := m.be, m.card.Route(m.card.Sel), m.opt.Pass, m.card.Prompt, m.ctx
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(parent, planTimeout)
		defer cancel()
		plan, err := be.LaunchPlan(ctx, r, "interactive", perm, pass, p)
		return planMsg{plan, err}
	}
}

func (m *Model) animTick() tea.Cmd {
	gen := m.animGen
	return tea.Tick(time.Second/time.Duration(m.opt.FPS), func(time.Time) tea.Msg { return animMsg{gen} })
}

// startFill begins the meter fill (or shows it full without motion).
func (m *Model) startFill() tea.Cmd {
	m.animGen++
	if !m.opt.Motion {
		m.card.Prog = 1
		return nil
	}
	m.pos, m.vel, m.frames = 0, 0, 0
	m.card.Prog = 0
	return m.animTick()
}

// stepFill advances the spring one frame; it reports false once settled.
func (m *Model) stepFill() bool {
	m.frames++
	m.pos, m.vel = m.spring.Update(m.pos, m.vel, 1)
	elapsed := time.Duration(m.frames) * time.Second / time.Duration(m.opt.FPS)
	if elapsed >= fillDuration {
		m.card.Prog = 1
		return false
	}
	m.card.Prog = min(max(m.pos, 0), 1)
	return true
}

func (m *Model) finish(d Decision) tea.Cmd {
	d.Pools = m.card.Pools
	d.Prompt = m.card.Prompt
	m.dec = d
	m.st = sDone
	m.cancel()
	return tea.Quit
}

func (m *Model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.input.SetWidth(max(m.width-4, 10))
		return m, nil
	case tea.BackgroundColorMsg:
		m.theme = NewTheme(msg.IsDark())
		return m, nil
	case spinMsg:
		m.spin++
		if m.st == sRouting || m.st == sLaunching {
			return m, spinTick()
		}
		return m, nil
	case poolsMsg:
		if msg.p != nil {
			m.card.Pools = msg.p
		}
		return m, nil
	case explainMsg:
		return m, m.onExplain(msg)
	case planMsg:
		return m, m.onPlan(msg)
	case animMsg:
		if msg.gen != m.animGen || m.st == sDone {
			return m, nil
		}
		if m.stepFill() {
			return m, m.animTick()
		}
		return m, nil
	case tea.KeyPressMsg:
		return m, m.onKey(msg)
	}
	if m.st == sEdit {
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(msg)
		return m, cmd
	}
	return m, nil
}

func (m *Model) onExplain(msg explainMsg) tea.Cmd {
	if msg.err != nil {
		var te *engine.TimeoutError
		if errors.As(msg.err, &te) {
			m.errText, m.routeErr, m.st = sentence(msg.err.Error()), true, sError
			return nil
		}
		return m.finish(Decision{Err: msg.err})
	}
	m.routeErr = false
	rows, sel := msg.ex.Rows()
	m.card.Mode = msg.ex.Mode
	m.card.ModeNotes = map[string]string{}
	for h, mi := range msg.ex.ModeByHarness {
		m.card.ModeNotes[h] = mi.Note
	}
	// The toggle follows the routed mode (on for yolo, off for anything
	// stricter) until you set it with y; after that a reroute never
	// changes it.
	if !m.yoloSet {
		m.card.Yolo = msg.ex.Mode == "yolo"
	}
	m.card.Task, m.card.Guessed, m.card.Prefer = msg.ex.Task, msg.ex.TaskGuessed, msg.ex.Prefer
	m.card.Rows, m.card.Sel, m.card.Efforts = rows, sel, map[int]string{}
	if m.opt.Yes {
		m.st = sLaunching
		return m.planCmd()
	}
	m.st = sCard
	return m.startFill()
}

func (m *Model) onPlan(msg planMsg) tea.Cmd {
	if msg.err == nil {
		// Check the environment now, so a refusal shows here and not after
		// the card is gone. The values themselves are dropped.
		base := m.opt.Environ
		if base == nil {
			base = os.Environ()
		}
		if _, err := launch.BuildEnv(base, msg.plan.EnvSet, msg.plan.EnvFrom, msg.plan.EnvUnset); err != nil {
			msg.err = err
		}
	}
	if msg.err != nil {
		var pe *engine.PlanError
		var ee *launch.EnvError
		var te *engine.TimeoutError
		if !errors.As(msg.err, &pe) && !errors.As(msg.err, &ee) && !errors.As(msg.err, &te) && m.opt.Yes {
			return m.finish(Decision{Err: msg.err})
		}
		m.errText = sentence(msg.err.Error())
		m.nextBest = m.nextRow()
		m.st = sError
		return nil
	}
	return m.finish(Decision{Launch: true, Route: m.card.Route(m.card.Sel), Plan: msg.plan, Yolo: m.card.Yolo})
}

func sentence(s string) string {
	s = strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(s), "afk: "))
	if s == "" {
		return "The engine gave no reason."
	}
	s = strings.ToUpper(s[:1]) + s[1:]
	if !strings.HasSuffix(s, ".") {
		s += "."
	}
	return s
}

// nextRow is the best other row, or -1.
func (m *Model) nextRow() int {
	for i := range m.card.Rows {
		if i != m.card.Sel {
			return i
		}
	}
	return -1
}

func (m *Model) onKey(k tea.KeyPressMsg) tea.Cmd {
	key := k.String()
	if key == "ctrl+c" {
		return m.finish(Decision{Cancelled: true})
	}
	switch m.st {
	case sRouting, sLaunching:
		if key == "esc" {
			return m.finish(Decision{Cancelled: true})
		}
		return nil
	case sEdit:
		switch key {
		case "enter":
			m.card.Prompt = strings.TrimSpace(m.input.Value())
			m.input.Blur()
			m.notice = ""
			return m.reroute()
		case "esc":
			m.input.Blur()
			m.st = sCard
			return nil
		}
		var cmd tea.Cmd
		m.input, cmd = m.input.Update(k)
		return cmd
	case sError:
		if m.routeErr {
			switch key {
			case "r":
				return m.reroute()
			case "esc":
				return m.finish(Decision{Cancelled: true})
			}
			return nil
		}
		switch key {
		case "r":
			m.st = sLaunching
			return m.launchCmds()
		case "enter":
			if m.nextBest >= 0 {
				m.card.Sel = m.nextBest
				m.st = sLaunching
				return m.launchCmds()
			}
		case "esc":
			return m.finish(Decision{Cancelled: true})
		}
		return nil
	case sWhy:
		switch key {
		case "?":
			m.st = sCard
			return nil
		case "esc":
			return m.finish(Decision{Cancelled: true})
		case "e", "y":
			m.st = sCard
			return m.cardKey(key)
		}
		return nil
	case sCard:
		return m.cardKey(key)
	}
	return nil
}

// reroute asks the engine again (after an edit, or a routing timeout).
func (m *Model) reroute() tea.Cmd {
	m.st = sRouting
	m.started = m.opt.Now()
	cmds := []tea.Cmd{m.explainCmd()}
	if m.opt.Motion {
		cmds = append(cmds, spinTick())
	}
	return tea.Batch(cmds...)
}

func (m *Model) launchCmds() tea.Cmd {
	m.started = m.opt.Now()
	cmds := []tea.Cmd{m.planCmd()}
	if m.opt.Motion {
		cmds = append(cmds, spinTick())
	}
	return tea.Batch(cmds...)
}

func (m *Model) cardKey(key string) tea.Cmd {
	armed := m.yoloArmed
	m.yoloArmed = false
	m.notice = ""
	r := m.card.Route(m.card.Sel)
	switch key {
	case "up", "k":
		m.card.Sel = (m.card.Sel - 1 + len(m.card.Rows)) % len(m.card.Rows)
	case "down", "j":
		m.card.Sel = (m.card.Sel + 1) % len(m.card.Rows)
	case "tab":
		if len(r.SupportedEfforts) == 0 {
			m.notice = routeName(r) + " takes no effort setting here"
			break
		}
		m.card.Efforts[m.card.Sel] = nextEffort(r.SupportedEfforts, r.Effort)
	case "e":
		m.st = sEdit
		m.input.SetValue(m.card.Prompt)
		m.input.CursorEnd()
		return m.input.Focus()
	case "y":
		switch {
		case m.card.Yolo:
			m.card.Yolo, m.yoloSet = false, true
			m.notice = "yolo is off: the CLI asks before it acts"
		case m.opt.YoloBlock != "":
			m.notice = m.opt.YoloBlock
		case armed:
			m.card.Yolo, m.yoloSet = true, true
		default:
			m.yoloArmed = true
			m.notice = "press y again: " + routeName(r) + " will act without asking (its own skip-permissions flag)"
		}
	case "?":
		m.st = sWhy
	case "w":
		m.notice = "where: only this terminal for now; background and remote runs come later"
	case "m":
		m.notice = "model picker comes in a later step"
	case "esc":
		return m.finish(Decision{Cancelled: true})
	case "enter":
		m.st = sLaunching
		return m.launchCmds()
	}
	return nil
}

// View draws the current state inline.
func (m *Model) View() tea.View {
	return tea.NewView(m.Render())
}

// Render is the view as a string (for tests and the final frame).
func (m *Model) Render() string {
	m.card.Now = m.opt.Now()
	t, w := m.theme, m.width
	compact := w > 0 && w < compactBelow
	switch m.st {
	case sRouting:
		if m.opt.Now().Sub(m.started) < routingDelay && m.opt.Motion {
			return join([]line{t.promptLine(m.card.Prompt, w)})
		}
		return join([]line{t.promptLine(m.card.Prompt, w), m.busyLine("Routing", m.card.Prefer)})
	case sEdit:
		l := line{sg(t.Accent, "› "), sg(t.Plain, m.input.View())}
		lines := []line{l}
		lines = append(lines, m.cardBody(compact, false)[1:]...)
		lines = append(lines, nil, line{sg(t.Key, " ↵"), sg(t.Dim, " route again  "), sg(t.Key, "esc"), sg(t.Dim, " keep the old prompt")})
		return join(lines)
	case sCard:
		lines := m.cardBody(compact, true)
		if m.notice != "" {
			lines = append(lines, fitLine(line{sg(t.Warn, " "+m.notice)}, max(w, 1)))
		}
		return join(lines)
	case sWhy:
		return join(t.WhyLines(m.card, w))
	case sLaunching:
		if len(m.card.Rows) == 0 {
			return join([]line{t.promptLine(m.card.Prompt, w), m.busyLine("Routing", m.card.Prefer)})
		}
		r := m.card.Route(m.card.Sel)
		if m.opt.Yes {
			return join([]line{t.promptLine(m.card.Prompt, w), m.busyLine("Starting", routeName(r)+" / "+r.Model)})
		}
		lines := m.cardBody(compact, false)
		return join(append(lines, nil, m.busyLine("Starting", routeName(r)+" / "+r.Model)))
	case sError:
		if m.routeErr || len(m.card.Rows) == 0 {
			return join(t.RouteErrorLines(m.card.Prompt, w, m.errText))
		}
		return join(t.ErrorLines(m.card, w, m.errText, m.nextBest))
	case sDone:
		if !m.dec.Launch && !m.dec.Cancelled || m.opt.Yes || len(m.card.Rows) == 0 {
			return ""
		}
		lines := m.cardBody(compact, false)
		if m.dec.Cancelled {
			lines = append(lines, nil, line{sg(t.Dim, " cancelled; nothing was started")})
		}
		return join(lines)
	}
	return ""
}

func (m *Model) cardBody(compact, hints bool) []line {
	if compact {
		return m.theme.CompactLines(m.card, m.width, hints)
	}
	return m.theme.CardLines(m.card, m.width, hints)
}

func (m *Model) busyLine(what, detail string) line {
	t := m.theme
	glyph := "·"
	if m.opt.Motion {
		glyph = spinFrames[m.spin%len(spinFrames)]
	}
	l := line{sg(t.Accent, " "+glyph+" "), sg(t.Bold, what)}
	if detail != "" {
		l = append(l, sg(t.Dim, "  "+detail))
	}
	if m.opt.Motion {
		l = append(l, sg(t.Dim, " · "+duration(m.opt.Now().Sub(m.started))))
	}
	return l
}
