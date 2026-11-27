package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"time"

	tea "charm.land/bubbletea/v2"
	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/term"

	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/core"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/mcp"
	"github.com/homelab-0/agent-flow-kit/internal/router"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
	"github.com/homelab-0/agent-flow-kit/internal/skills"
	"github.com/homelab-0/agent-flow-kit/internal/tui"
)

// panelSource feeds the control panel's tabs from the engine, harness
// discovery, the run records and config.toml. Only SkillsDo changes
// anything; the other action keys run afk subcommands.
type panelSource struct {
	c *core.Core
	// discover finds the CLIs (harness.Discover; tests replace it).
	discover func(ctx context.Context) harness.Report
	// repo is the project routing uses (--repo); "" is the current
	// directory.
	repo string
}

func (s panelSource) getenv(k string) string {
	if s.c.Getenv == nil {
		return ""
	}
	return s.c.Getenv(k)
}

func newPanelSource(c *core.Core, repo string) panelSource {
	return panelSource{c: c, repo: repo, discover: func(ctx context.Context) harness.Report {
		return harness.Discover(ctx, c.Harness, harness.Options{})
	}}
}

// planPool is the plan pool each CLI's own login draws on.
var planPool = map[string]string{
	"claude": "anthropic-max", "codex": "openai-plus", "grok": "xai-grok", "agy": "antigravity-pool", "opencode": "opencode-free",
}

var planName = map[string]string{
	"anthropic-max": "Claude plan", "openai-plus": "ChatGPT plan", "xai-grok": "SuperGrok", "antigravity-pool": "Google AI plan",
}

func (s panelSource) Harnesses(ctx context.Context) (*tui.HarnessesView, error) {
	rep := s.discover(ctx)
	r, settings, err := s.c.Router(ctx, s.repo)
	if err != nil {
		return nil, err
	}
	v := &tui.HarnessesView{}
	for _, h := range rep.Harnesses {
		row := tui.HarnessRow{
			Name: h.Name, Display: h.Display, Version: h.Version, Installed: h.Installed,
			Path: h.Binary, Method: h.InstallMethod, Update: strings.Join(h.UpdateCommand, " "), Note: h.AuthNote,
		}
		if h.Problem != "" {
			row.Note = h.Problem
		}
		switch h.Auth {
		case harness.AuthOK:
			row.SignIn = "signed in"
		case harness.AuthSignedOut:
			row.SignIn = "signed out"
		default:
			row.SignIn = "unknown"
		}
		if settings.Disabled[h.Name] {
			row.Routes = "off"
		} else {
			row.Routes, row.Models = harnessRoutes(r, h.Name)
		}
		if p, ok := r.Probe.Pools[planPool[h.Name]]; ok && h.Installed {
			row.Usage = usageText(p)
		}
		v.Rows = append(v.Rows, row)
	}
	// Installed first, in discovery's order.
	sort.SliceStable(v.Rows, func(i, j int) bool { return v.Rows[i].Installed && !v.Rows[j].Installed })
	return v, nil
}

// harnessRoutes says what a CLI can be routed to (its plan, the gateway,
// local engines) and the models it runs.
func harnessRoutes(r *router.Router, h string) (string, []string) {
	var kinds []string
	var models []string
	seen := map[string]bool{}
	gw, local := 0, 0
	for _, c := range r.AllCandidates(false) {
		if c.Harness != h {
			continue
		}
		switch {
		case c.LaunchClass == router.LocalLaunch:
			local++
			continue
		case strings.HasSuffix(c.LaunchClass, "-gateway"):
			if r.Probe.Harnesses["litellm_gateway"].Online {
				gw++
			}
			continue
		}
		if !seen[c.Model] {
			seen[c.Model] = true
			models = append(models, c.Model)
		}
	}
	if len(models) > 0 {
		kinds = append(kinds, "plan")
	}
	if gw > 0 {
		kinds = append(kinds, "gw")
	}
	if local > 0 {
		kinds = append(kinds, "local")
	}
	if len(models) > 4 {
		models = append(models[:4], fmt.Sprintf("+%d more", len(models)-4))
	}
	if gw > 0 {
		models = append(models, fmt.Sprintf("+%d via gateway", gw))
	}
	if local > 0 {
		models = append(models, fmt.Sprintf("+%d local", local))
	}
	if len(kinds) == 0 {
		return "—", models
	}
	return strings.Join(kinds, "+"), models
}

// usageText is a pool's headroom in words.
func usageText(p router.Pool) string {
	var parts []string
	if p.HeadroomPct != nil {
		w := "5h"
		if p.Window == "weekly" {
			w = "week"
		}
		s := fmt.Sprintf("%s %.0f%% left", w, *p.HeadroomPct)
		if p.QuotaSource == "local_5h_activity" {
			s += " (estimated)"
		}
		parts = append(parts, s)
	}
	if p.WeeklyUsedPct != nil && p.Window != "weekly" {
		parts = append(parts, fmt.Sprintf("week %.0f%% left", 100-*p.WeeklyUsedPct))
	}
	return strings.Join(parts, " · ")
}

func (s panelSource) Benchmarks(ctx context.Context, task string) (*tui.BenchView, error) {
	r, settings, err := s.c.Router(ctx, s.repo)
	if err != nil {
		return nil, err
	}
	stage, risk, err := router.TaskRoute(task, "balanced")
	if err != nil {
		return nil, err
	}
	tc := router.TaskClass(stage, risk, []string{"code"}, 1, 0)
	outcomes := core.Outcomes(runrec.Load(runrec.DirFor(s.c.Home, s.getenv), time.Now().Add(-core.OutcomeMaxAge)))
	type acc struct {
		row     tui.BenchRow
		vias    map[string]bool
		counted map[router.OutcomeKey]bool // outcome keys already in the row
	}
	rows := map[string]*acc{}
	var order []string
	names := map[string]bool{}
	for _, c := range r.AllCandidates(settings.AllowMetered) {
		if !r.Probe.Harnesses[c.Harness].Installed || settings.Disabled[c.Harness] {
			continue
		}
		gw := strings.HasSuffix(c.LaunchClass, "-gateway")
		if gw && !r.Probe.Harnesses["litellm_gateway"].Online {
			continue
		}
		// The same pools routing skips: a spent or signed-out plan is
		// no route today.
		if p, ok := r.Probe.Pools[c.EntitlementPool]; ok && (p.State == "exhausted" || p.State == "offline" || p.State == "auth_required") {
			continue
		}
		bm, ok := c.Benchmarks[tc]
		if !ok || bm.Score == nil {
			continue
		}
		key := c.Model
		a := rows[key]
		if a == nil {
			basis := bm.Basis
			if basis == "" {
				basis = "estimate"
			}
			sc := *bm.Score
			a = &acc{row: tui.BenchRow{Model: c.Model, Score: &sc, Basis: basis}, vias: map[string]bool{}, counted: map[router.OutcomeKey]bool{}}
			rows[key] = a
			order = append(order, key)
			if bm.Name != "" {
				names[bm.Name] = true
			}
		}
		via := engine.Route{Harness: c.Harness, LaunchClass: c.LaunchClass}
		vk := c.Harness
		switch {
		case c.LaunchClass == router.LocalLaunch:
			le := localEngineOf(r, c.EngineURL())
			via.Engine, vk = le, "local:"+le
		case gw:
			via.GatewayKind, vk = gatewayKindFor(settings), "gw"
		}
		if !a.vias[vk] {
			a.vias[vk] = true
			a.row.Via = append(a.row.Via, via)
		}
		// Two endpoints serving one model share its ratings: count them once.
		okey := router.OutcomeKeyFor(c.Harness, c.CanonicalModel, c.Model, tc)
		if a.counted[okey] {
			continue
		}
		a.counted[okey] = true
		if st, found := outcomes[okey]; found {
			a.row.Solved += st.Solved
			a.row.Partly += st.Partly
			a.row.Wrong += st.Wrong
		}
	}
	v := &tui.BenchView{Task: task}
	for _, k := range order {
		v.Rows = append(v.Rows, rows[k].row)
	}
	sort.SliceStable(v.Rows, func(i, j int) bool { return *v.Rows[i].Score > *v.Rows[j].Score })
	if len(v.Rows) > 12 {
		v.Rows = v.Rows[:12]
	}
	var bn []string
	for n := range names {
		bn = append(bn, n)
	}
	sort.Strings(bn)
	src := ""
	if len(bn) > 0 {
		src = bn[0]
		if len(bn) > 1 {
			src += fmt.Sprintf(" +%d more", len(bn)-1)
		}
	}
	if r.Catalog != nil && r.Catalog.UpdatedAt != "" {
		if src != "" {
			src += " · "
		}
		src += "catalog " + r.Catalog.UpdatedAt
	}
	v.Source = src
	ex, err := s.c.Explain(ctx, engine.RouteFlags{Task: task, Repo: s.repo}, "")
	if err != nil {
		v.Problems = "effective scores: " + err.Error()
	} else {
		v.Routes = ex.ByHarness
	}
	return v, nil
}

func localEngineOf(r *router.Router, u string) string {
	for _, le := range r.Probe.Local {
		if le.URL == u {
			return le.Engine
		}
	}
	return ""
}

func gatewayKindFor(s core.Settings) string {
	if name, g, ok := s.GatewayFor(s.GatewayURL); ok && name != "" {
		return g.Kind
	}
	return ""
}

func (s panelSource) Status(ctx context.Context) (*tui.StatusView, error) {
	r, settings, err := s.c.Router(ctx, s.repo)
	if err != nil {
		return nil, err
	}
	v := &tui.StatusView{Updated: time.Now()}
	for _, h := range []string{"claude", "codex", "grok", "agy"} {
		if !r.Probe.Harnesses[h].Installed {
			continue
		}
		pid := planPool[h]
		p, ok := r.Probe.Pools[pid]
		if !ok {
			continue
		}
		row := tui.PlanRow{Harness: h, Plan: planName[pid], SignIn: "ok"}
		if p.Window == "weekly" {
			row.Week = p.HeadroomPct
			if p.FiveHourUsedPct != nil {
				f := 100 - *p.FiveHourUsedPct
				row.FiveHour = &f
			}
		} else {
			row.FiveHour = p.HeadroomPct
			if p.WeeklyUsedPct != nil {
				w := 100 - *p.WeeklyUsedPct
				row.Week = &w
			}
		}
		switch p.State {
		case "auth_required":
			row.SignIn = "sign in"
		case "offline":
			row.SignIn = "offline"
		}
		if p.QuotaSource == "local_5h_activity" {
			row.Note = "estimated from recent sessions; " + h + " doesn't report its usage outside a one-shot run"
		}
		v.Plans = append(v.Plans, row)
	}
	if settings.GatewayURL != "" {
		g := r.Probe.Harnesses["litellm_gateway"]
		row := &tui.GatewayRow{Name: settings.GatewayName, State: "down", Detail: redactHost(settings.GatewayURL)}
		if row.Name == "" || row.Name == "default" {
			row.Name = "gateway"
		}
		if name, cfg, ok := settings.GatewayFor(settings.GatewayURL); ok {
			row.Name, row.Kind, row.Engine, row.EngineHost = name, cfg.Kind, cfg.Engine, cfg.Host
		}
		if g.Online {
			row.State = "up"
			row.Detail += " · " + fmt.Sprintf("%d models", len(g.Models))
		}
		v.Gateway = row
	}
	for _, le := range r.Probe.Local {
		where := "this PC"
		if r.Probe.LocalGPU != "" {
			where += " · " + r.Probe.LocalGPU
		}
		v.Engines = append(v.Engines, tui.EngineRow{Engine: le.Engine, State: le.State, Where: where, Models: le.Models})
	}
	for _, rec := range runrec.Load(runrec.DirFor(s.c.Home, s.getenv), time.Now().Add(-30*24*time.Hour)) {
		row := tui.RunRow{ID: rec.ID, Where: rec.Where, CLI: rec.Route.Harness, Model: rec.Route.Model, Exit: rec.Exit,
			Duration: time.Duration(rec.DurationS) * time.Second}
		if rec.Route.IsLocal() && rec.Route.Engine != "" {
			row.CLI = rec.Route.Engine
		}
		if rec.Outcome != nil {
			row.Outcome = *rec.Outcome
		}
		if t, err := time.Parse(time.RFC3339, rec.StartedAt); err == nil {
			row.Started = t
		}
		v.Runs = append(v.Runs, row)
		if len(v.Runs) >= 15 {
			break
		}
	}
	return v, nil
}

// redactHost is a URL's host only (never user info or a query).
func redactHost(u string) string {
	r := engine.Route{LitellmBaseURL: u}.Redacted()
	h := strings.TrimPrefix(strings.TrimPrefix(r.LitellmBaseURL, "https://"), "http://")
	return strings.TrimRight(h, "/")
}

func (s panelSource) Config(ctx context.Context) (*tui.ConfigView, error) {
	paths := config.PathsFor(s.c.Home, s.getenv)
	v := &tui.ConfigView{Path: paths.Config}
	if _, err := os.Stat(paths.Config); err == nil {
		v.Exists = true
	}
	repo := s.repo
	if repo == "" {
		repo = s.c.Cwd
	}
	st, err := s.c.LoadSettings(repo)
	if err != nil {
		return nil, err
	}
	yes := map[bool]string{true: "on", false: "off"}
	add := func(k, val string) { v.Rows = append(v.Rows, [2]string{k, val}) }
	add("route.prefer", st.Prefer)
	add("route.failover", st.Failover)
	add("route.learn", yes[st.Learn])
	add("route.pacing", yes[st.Pacing])
	add("route.prefer_free", yes[st.PreferFree])
	add("route.allow_metered", yes[st.AllowMetered])
	add("route.allow_free_reviewers", yes[st.AllowFreeReviewers])
	add("permissions.default", st.Mode)
	gw := "none"
	if st.GatewayURL != "" {
		gw = redactHost(st.GatewayURL)
		if st.GatewayName != "" {
			gw = st.GatewayName + " · " + gw
		}
	}
	add("gateway", gw)
	local := "off"
	if len(st.LocalURLs) > 0 {
		local = fmt.Sprintf("%d addresses on this PC", len(st.LocalURLs))
	}
	add("local.engines", local)
	if st.LocalGPU != "" {
		add("local.gpu", st.LocalGPU)
	}
	var off []string
	for h, d := range st.Disabled {
		if d {
			off = append(off, h)
		}
	}
	sort.Strings(off)
	if len(off) > 0 {
		add("harness (off)", strings.Join(off, ", "))
	}
	add("trust.repos", fmt.Sprintf("%d trusted", len(st.TrustedDirs)))
	add("bench.autosync", yes[st.BenchAutosync])
	for _, w := range st.Warnings {
		v.Warnings = append(v.Warnings, w.String())
	}
	return v, nil
}

func (s panelSource) Command(args ...string) []string {
	exe, err := os.Executable()
	if err != nil {
		exe = "afk"
	}
	return append([]string{exe}, args...)
}

const statusHelp = `Usage: afk status [--tab harnesses|bench|skills|mcp|runs|config]

Opens AFK's control panel full screen on the Runs tab (or the one --tab
names): plan usage, the gateway and local engines, and recent runs. 1-7
switch tabs, q quits. Nothing is changed unless you press an action key.
`

// statusCmd is `afk status`: the control panel on its own.
func statusCmd(argv []string, stdout, stderr io.Writer) int {
	tab := tui.TabRuns
	for i := 0; i < len(argv); i++ {
		switch a := argv[i]; {
		case a == "-h" || a == "--help" || a == "help":
			fmt.Fprint(stdout, statusHelp)
			return 0
		case a == "--tab" && i+1 < len(argv):
			i++
			t, ok := tui.TabFor(argv[i])
			if !ok || t == tui.TabRoute {
				fmt.Fprintf(stderr, "afk status: unknown tab %q\n", argv[i])
				return 2
			}
			tab = t
		default:
			fmt.Fprintf(stderr, "afk status: unknown argument %q\n\n%s", a, statusHelp)
			return 2
		}
	}
	if !term.IsTerminal(os.Stdin.Fd()) || !term.IsTerminal(os.Stdout.Fd()) {
		fmt.Fprintln(stderr, "afk status: needs a terminal (for scripts: afk harness --json, afk --explain --json)")
		return 2
	}
	dark := true
	if os.Getenv("NO_COLOR") == "" {
		dark = lipgloss.HasDarkBackground(os.Stdin, os.Stdout)
	}
	logos := setupLogos()
	theme := tui.NewTheme(dark).WithLogos(logos)
	p := tui.NewPanel(context.Background(), newPanelSource(core.New(), ""), theme, tab, headerInfo().Version, nil).Standalone()
	if _, err := tea.NewProgram(tui.PanelModel{P: p}).Run(); err != nil {
		fmt.Fprintln(stderr, "afk:", err)
		return 1
	}
	return 0
}

func (s panelSource) skills() skillsDeps {
	t, u := skillTargets(s.c.Harness)
	return skillsDeps{env: skillsEnvFor(s.c.Home, s.getenv), targets: t, unsupported: u}
}

// Skills is the Skills tab.
func (s panelSource) Skills(ctx context.Context) (*tui.SkillsView, error) {
	d := s.skills()
	st, err := d.env.Scan(d.targets)
	if err != nil {
		return nil, err
	}
	return skillsView(d, st, s.c.Home), nil
}

func skillsView(d skillsDeps, st *skills.Status, home string) *tui.SkillsView {
	tilde := func(p string) string {
		if home != "" && strings.HasPrefix(p, home+string(os.PathSeparator)) {
			return "~" + strings.TrimPrefix(p, home)
		}
		return p
	}
	v := &tui.SkillsView{Source: tilde(st.Central), Cols: harnessNames(st.Targets), Unsupported: d.unsupported,
		Pending: len(st.Actions), Problems: st.Problems}
	for _, sk := range st.Skills {
		r := tui.SkillRow{Name: sk.Name, Central: sk.Central, Cells: map[string]string{}}
		for h, c := range sk.Cells {
			r.Cells[h] = string(c)
		}
		v.Rows = append(v.Rows, r)
	}
	dirs := map[string]string{}
	for _, t := range st.Targets {
		dirs[t.Harness] = tilde(t.Dir)
	}
	for _, dr := range st.Drift {
		v.Drift = append(v.Drift, tui.SkillDrift{Skill: dr.Skill, Harness: dr.Harness, Dir: dirs[dr.Harness],
			Modified: dr.Modified, Lines: d.env.Changed(st.Targets, dr.Skill, dr.Harness)})
	}
	return v
}

// SkillsDo runs a skills action for the tab's keys.
func (s panelSource) SkillsDo(ctx context.Context, op string, args ...string) (string, error) {
	d := s.skills()
	two := func() (string, string, error) {
		if len(args) != 2 {
			return "", "", fmt.Errorf("skills %s needs a skill and a CLI", op)
		}
		return args[0], args[1], nil
	}
	switch op {
	case "sync":
		res, err := d.env.Sync(d.targets)
		if err != nil {
			return "", err
		}
		if len(res.Done) == 0 {
			return "Everything is in sync.", nil
		}
		return fmt.Sprintf("Synced %s.", plural(len(res.Done), "change")), nil
	case "keep", "restore":
		sk, h, err := two()
		if err != nil {
			return "", err
		}
		if op == "keep" {
			if _, err := d.env.Keep(d.targets, sk, h); err != nil {
				return "", err
			}
			return fmt.Sprintf("Central %s is now %s's copy. Press s to copy it into the other CLIs.", sk, h), nil
		}
		if _, err := d.env.Restore(d.targets, sk, h); err != nil {
			return "", err
		}
		return fmt.Sprintf("Put central %s back in %s (its copy is backed up).", sk, h), nil
	case "enable", "disable":
		sk, h, err := two()
		if err != nil {
			return "", err
		}
		if err := d.env.SetEnabled(sk, h, op == "enable"); err != nil {
			return "", err
		}
		return fmt.Sprintf("%s %sd for %s. Press s to apply it.", sk, op, h), nil
	}
	return "", fmt.Errorf("unknown skills action %q", op)
}

func (s panelSource) mcp() (mcpDeps, error) {
	repo := s.repo
	if repo == "" {
		repo = s.c.Cwd
	}
	st, err := s.c.LoadSettings(repo)
	if err != nil {
		return mcpDeps{}, err
	}
	t, u := mcpTargets(s.c.Harness)
	return mcpDeps{env: mcpEnvFor(s.c.Home, s.getenv, st), targets: t, unsupported: u, getenv: s.getenv}, nil
}

// MCP is the MCP tab.
func (s panelSource) MCP(ctx context.Context) (*tui.MCPView, error) {
	d, err := s.mcp()
	if err != nil {
		return nil, err
	}
	st, err := d.env.Scan(d.targets)
	if err != nil {
		return nil, err
	}
	return mcpView(d, st, s.c.Home, time.Now()), nil
}

func mcpView(d mcpDeps, st *mcp.Status, home string, now time.Time) *tui.MCPView {
	tilde := func(p string) string {
		if home != "" && strings.HasPrefix(p, home+string(os.PathSeparator)) {
			return "~" + strings.TrimPrefix(p, home)
		}
		return p
	}
	v := &tui.MCPView{Source: tilde(st.Config), Unsupported: d.unsupported, Pending: len(st.Actions), Problems: st.Problems}
	for _, t := range st.Targets {
		v.Cols = append(v.Cols, t.Harness)
	}
	via := map[string]string{}
	for _, sv := range st.Servers {
		via[sv.Name] = sv.Via
	}
	for _, r := range st.Rows {
		row := tui.MCPRow{Name: r.Name, Via: via[r.Name], Listed: r.Listed, Tools: -1, Status: "untested", Cells: map[string]string{}, Notes: r.Notes}
		if tr, ok := st.Tested[r.Name]; ok && !tr.At.IsZero() {
			row.Status, row.Tested = "down", ago(now.Sub(tr.At))
			if tr.OK {
				row.Status, row.Tools = "up", tr.Tools
			}
		}
		for h, c := range r.Cells {
			row.Cells[h] = string(c)
		}
		v.Rows = append(v.Rows, row)
	}
	for _, dr := range st.Drift {
		v.Drift = append(v.Drift, tui.MCPDrift{Server: dr.Server, Harness: dr.Harness, File: tilde(dr.File)})
	}
	return v
}

// MCPDo runs an MCP action for the tab's keys.
func (s panelSource) MCPDo(ctx context.Context, op string, args ...string) (string, error) {
	d, err := s.mcp()
	if err != nil {
		return "", err
	}
	two := func() (string, string, error) {
		if len(args) != 2 {
			return "", "", fmt.Errorf("mcp %s needs a server and a CLI", op)
		}
		return args[0], args[1], nil
	}
	switch op {
	case "sync":
		res, err := d.env.Sync(d.targets)
		if err != nil {
			return "", err
		}
		if len(res.Done) == 0 {
			return "Everything is in sync.", nil
		}
		return fmt.Sprintf("Synced %s.", plural(len(res.Done), "change")), nil
	case "test":
		if len(args) != 1 {
			return "", fmt.Errorf("mcp test needs a server")
		}
		servers, err := mcp.Load(d.env.Config, d.env.Gateways)
		if err != nil {
			return "", err
		}
		for _, sv := range servers {
			if sv.Name != args[0] {
				continue
			}
			tools, err := mcp.ListTools(ctx, sv, d.getenv)
			rec := mcp.Tested{OK: err == nil, Tools: len(tools), At: time.Now().UTC()}
			if err != nil {
				rec.Error = err.Error()
			}
			_ = d.env.Record(sv.Name, rec)
			if err != nil {
				return "", fmt.Errorf("%s: %w", sv.Name, err)
			}
			return fmt.Sprintf("%s is up: %s.", sv.Name, plural(len(tools), "tool")), nil
		}
		return "", fmt.Errorf("no server %q in mcp.toml", args[0])
	case "keep", "restore":
		sv, h, err := two()
		if err != nil {
			return "", err
		}
		if op == "keep" {
			if _, err := d.env.Keep(d.targets, sv, h); err != nil {
				return "", err
			}
			return fmt.Sprintf("%s in %s is now yours; AFK won't change it again.", sv, h), nil
		}
		if _, err := d.env.Restore(d.targets, sv, h); err != nil {
			return "", err
		}
		return fmt.Sprintf("Wrote AFK's %s back into %s (the file is backed up).", sv, h), nil
	case "enable", "disable":
		sv, h, err := two()
		if err != nil {
			return "", err
		}
		if err := d.env.SetEnabled(sv, h, op == "enable"); err != nil {
			return "", err
		}
		return fmt.Sprintf("%s %sd for %s. Press s to apply it.", sv, op, h), nil
	}
	return "", fmt.Errorf("unknown mcp action %q", op)
}
