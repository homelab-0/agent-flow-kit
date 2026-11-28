package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
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
	"anthropic-max": "Claude plan", "openai-plus": "ChatGPT plan", "xai-grok": "Grok plan", "antigravity-pool": "Google plan",
}

// planLabel names a plan pool. AFK doesn't know which tier of a plan
// someone pays for, so it names the vendor's plan in general and adds the
// tier only when the CLI itself reported one.
func planLabel(pid, reported string) string {
	name := planName[pid]
	if reported == "" {
		return name
	}
	if name == "" {
		return reported
	}
	return name + " · " + reported
}

// signInText is a CLI's sign-in state in words. "signed in" is kept for
// the CLI's own status command saying so; a login file that is merely
// there is "login on disk".
func signInText(h harness.Info) string {
	switch {
	case h.Auth == harness.AuthOK && h.AuthChecked == harness.AuthByStatus:
		return "signed in"
	case h.Auth == harness.AuthOK:
		return "login on disk"
	case h.Auth == harness.AuthSignedOut:
		return "signed out"
	}
	return "unknown"
}

// setAsideNote says why a failed run set a plan aside and for how long.
func setAsideNote(p router.Pool, now time.Time) string {
	why := "an error"
	if p.DegradedKind != nil {
		switch *p.DegradedKind {
		case "quota":
			why = "a rate-limit or quota error"
		case "auth":
			why = "a sign-in error"
		}
	}
	s := "set aside after a run failed with " + why
	if p.SetAsideUntil != nil {
		if t, err := time.Parse(time.RFC3339, *p.SetAsideUntil); err == nil && t.After(now) {
			s += ", for another " + shortSpan(t.Sub(now))
		}
	}
	return s + "; this is not a usage reading"
}

// shortSpan is a rough length of time: 40s, 12m, 3h.
func shortSpan(d time.Duration) string {
	switch {
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d/time.Second))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d/time.Minute))
	}
	return fmt.Sprintf("%dh", int(d/time.Hour))
}

// ClearMarks removes every failed-run mark, as afk pools clear does.
func (s panelSource) ClearMarks(context.Context) (string, error) {
	path := router.ProbeEnv{Home: s.c.Home, Getenv: s.getenv}.SignalsPath()
	removed, err := router.ClearSignals(path, nil, false)
	if err != nil {
		return "", err
	}
	if len(removed) == 0 {
		return "No failed-run mark to clear.", nil
	}
	return "Cleared " + strings.Join(removed, ", ") + ".", nil
}

func (s panelSource) Harnesses(ctx context.Context) (*tui.HarnessesView, error) {
	rep := s.discover(ctx)
	r, settings, err := s.c.Router(ctx, s.repo)
	if err != nil {
		return nil, err
	}
	v := &tui.HarnessesView{AutoDiscover: settings.AutoDiscover}
	for _, h := range rep.Harnesses {
		row := tui.HarnessRow{
			Name: h.Name, Display: h.Display, Version: h.Version, Installed: h.Installed,
			Path: h.Binary, Method: h.InstallMethod, Update: strings.Join(h.UpdateCommand, " "), Note: h.AuthNote,
		}
		if h.Problem != "" {
			row.Note = h.Problem
		}
		row.SignIn = signInText(h)
		if h.Auth == harness.AuthOK && h.AuthChecked == harness.AuthByFile && row.Note == "" {
			row.Note = "a login is on disk; " + h.Name + " has no status command, so AFK can't confirm it still works"
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
	switch {
	case p.HeadroomPct != nil:
		w := "5h"
		switch p.Window {
		case "weekly":
			w = "week"
		case "other":
			// A window of another length (a month, say).
			w = "this period"
		}
		parts = append(parts, fmt.Sprintf("%s %.0f%% left", w, *p.HeadroomPct))
	case p.QuotaSource == router.SourceSignedOut:
		return "not signed in"
	case p.QuotaSource == router.SourceUnknown:
		return "usage unknown"
	}
	if p.WeeklyUsedPct != nil && p.Window != "weekly" {
		parts = append(parts, fmt.Sprintf("week %.0f%% left", 100-*p.WeeklyUsedPct))
	}
	if noLimit(p.LimitWindows, "5h") {
		parts = append(parts, "no 5-hour limit")
	}
	if noLimit(p.LimitWindows, "weekly") {
		parts = append(parts, "no weekly limit")
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
	recs := runrec.Load(runrec.DirFor(s.c.Home, s.getenv), time.Now().Add(-30*24*time.Hour))
	runsToday := map[string]int{}
	y, m, d := v.Updated.Date()
	for _, rec := range recs {
		if t, err := time.Parse(time.RFC3339, rec.StartedAt); err == nil && !rec.Route.IsLocal() {
			if ty, tm, td := t.In(v.Updated.Location()).Date(); ty == y && tm == m && td == d {
				runsToday[rec.Route.Harness]++
			}
		}
	}
	found := map[string]harness.Info{}
	for _, h := range s.discover(ctx).Harnesses {
		found[h.Name] = h
	}
	for _, h := range []string{"claude", "codex", "grok", "agy"} {
		if !r.Probe.Harnesses[h].Installed {
			continue
		}
		pid := planPool[h]
		p, ok := r.Probe.Pools[pid]
		if !ok {
			continue
		}
		// Sign-in is what the CLI itself (or, failing that, its login on
		// disk) says: never "ok" by default.
		row := tui.PlanRow{Harness: h, Plan: planLabel(pid, p.Plan), SignIn: "unknown"}
		if in, ok := found[h]; ok {
			row.SignIn = signInText(in)
		}
		if p.Window == "weekly" {
			row.Week = p.HeadroomPct
			if p.FiveHourUsedPct != nil {
				f := 100 - *p.FiveHourUsedPct
				row.FiveHour = &f
			}
		} else {
			if p.Window != "other" {
				row.FiveHour = p.HeadroomPct
			}
			if p.WeeklyUsedPct != nil {
				w := 100 - *p.WeeklyUsedPct
				row.Week = &w
			}
		}
		row.NoFiveHour, row.NoWeek = noLimit(p.LimitWindows, "5h"), noLimit(p.LimitWindows, "weekly")
		if p.SetAside {
			row.SetAside, row.Note = true, setAsideNote(p, v.Updated)
		} else if p.ObservedAt != nil && p.HeadroomPct != nil {
			if a := engine.ReadAgo(*p.ObservedAt, v.Updated); a != "" {
				row.Note = "as " + h + " reported it " + a
			}
		}
		if p.QuotaSource == router.SourceVendor && !p.SetAside {
			row.Note = "from " + vendorOf(h) + "'s usage service, with " + h + "'s saved login (you turned this on)"
		}
		if p.Window == "other" && p.HeadroomPct != nil && !p.SetAside {
			row.Note = strings.TrimPrefix(fmt.Sprintf("%.0f%% left this period · %s", *p.HeadroomPct, row.Note), " · ")
			row.Note = strings.TrimSuffix(row.Note, " · ")
		}
		switch p.QuotaSource {
		case router.SourceSignedOut:
			row.SignIn = "signed out"
		case router.SourceUnknown:
			row.Note = h + " hasn't reported its plan usage, so AFK shows none"
			if p.UsageNote != "" {
				// The CLI's own module says why it has no figure.
				row.Note = p.UsageNote + ", so AFK shows none"
			}
		}
		if x := extraText(p.Extra); x != "" {
			if row.Note != "" {
				row.Note += " · "
			}
			row.Note += x
		}
		if p.ResetsAt != nil && (p.Window == "5h" || p.Window == "weekly") {
			if t, err := time.Parse(time.RFC3339, *p.ResetsAt); err == nil {
				row.Resets, row.ResetsWindow = t, p.Window
			}
		}
		row.Pace, row.Leans = paceText(p.Pacing)
		row.RunsToday = runsToday[h]
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
	for _, rec := range recs {
		row := tui.RunRow{ID: rec.ID, Where: rec.Where, CLI: rec.Route.Harness, Model: rec.Route.Model, Effort: rec.Route.Effort, Exit: rec.Exit,
			Duration: time.Duration(rec.DurationS) * time.Second, PoolBefore: rec.PoolBefore, PoolAfter: rec.PoolAfter,
			Files: rec.FilesChanged, Commits: rec.Commits}
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
		if len(v.Runs) >= 50 {
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
	v.Edit = map[string]tui.ConfigEdit{
		"route.prefer":        {Choices: []string{"balanced", "cheap", "best"}},
		"route.failover":      {Choices: []string{"any", "same-pool", "none"}},
		"permissions.default": {Choices: []string{"read-only", "ask", "edits", "auto"}},
		"trust.repos":         {Value: strings.Join(st.TrustedDirs, ", "), Hint: "folders where yolo is allowed, separated by commas"},
	}
	for _, k := range []string{"route.learn", "route.pacing", "route.prefer_free", "route.allow_metered", "route.allow_free_reviewers", "bench.autosync", "discovery.auto"} {
		v.Edit[k] = tui.ConfigEdit{Choices: []string{"on", "off"}}
	}
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
	// Each gateway in config.toml, field by field, and a row to add one.
	gwNames := make([]string, 0, len(st.Gateways))
	for n := range st.Gateways {
		gwNames = append(gwNames, n)
	}
	sort.Strings(gwNames)
	for _, n := range gwNames {
		g, sec := st.Gateways[n], "gateway."+n
		orNone := func(s string) string {
			if s == "" {
				return "not set"
			}
			return s
		}
		// An address can carry a password; it is shown without one, and
		// the input then starts empty.
		shown, start := orNone(redactHost(g.URL)), g.URL
		if u, err := url.Parse(g.URL); err == nil && u.User != nil {
			start = ""
		}
		add(sec+".url", shown)
		v.Edit[sec+".url"] = tui.ConfigEdit{Value: start, Hint: "the gateway's base address, such as https://gw.example:4000", Remove: sec}
		add(sec+".key", orNone(g.Key))
		v.Edit[sec+".key"] = tui.ConfigEdit{Value: g.Key, Hint: "where the key is, never the key: env:NAME, file:/path, op://vault/item, keychain:NAME or cmd:...", Remove: sec}
		add(sec+".default", yes[g.Default])
		v.Edit[sec+".default"] = tui.ConfigEdit{Choices: []string{"on", "off"}, Remove: sec}
		add(sec+".kind", orNone(g.Kind))
		v.Edit[sec+".kind"] = tui.ConfigEdit{Value: g.Kind, Hint: "what it is, for the route card: litellm, openrouter, agentgateway, ...", Remove: sec}
		add(sec+".engine", orNone(g.Engine))
		v.Edit[sec+".engine"] = tui.ConfigEdit{Value: g.Engine, Hint: "what serves its models, for the route card: vllm, ollama, ...", Remove: sec}
		add(sec+".host", orNone(g.Host))
		v.Edit[sec+".host"] = tui.ConfigEdit{Value: g.Host, Hint: "where that runs, for the route card", Remove: sec}
	}
	add(gatewayNew, "↵ to add one")
	v.Edit[gatewayNew] = tui.ConfigEdit{Hint: "a name and its address, for example: work https://gw.example:4000"}
	local := "off"
	if len(st.LocalURLs) > 0 {
		local = fmt.Sprintf("auto · %d addresses on this PC", len(st.LocalURLs))
	}
	add("local.engines", local)
	v.Edit["local.engines"] = tui.ConfigEdit{Choices: []string{"auto", "off"}}
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
	// One switch per CLI whose vendor can be asked for usage. Turning it
	// on shows the warning and takes one more enter; off asks nothing.
	for _, l := range harness.VendorLookups() {
		k := "harness." + l.Harness + ".vendor_usage"
		add(k, yes[st.VendorUsage[l.Harness]])
		v.Edit[k] = tui.ConfigEdit{Choices: []string{"on", "off"}, Confirm: vendorUsageWarning(l)}
	}
	add("discovery.auto", yes[st.AutoDiscover])
	add("trust.repos", fmt.Sprintf("%d trusted", len(st.TrustedDirs)))
	add("bench.autosync", yes[st.BenchAutosync])
	for _, w := range st.Warnings {
		v.Warnings = append(v.Warnings, w.String())
	}
	return v, nil
}

// vendorUsageWarning is what the Config tab says before the vendor usage
// lookup is switched on for a CLI.
func vendorUsageWarning(l harness.VendorLookup) string {
	return "On lets AFK read the login " + l.Display + " saved on this PC and ask " + l.Vendor +
		" for your plan usage, the way " + l.Display + "'s own usage screen does. " + l.Vendor +
		"'s terms may not allow another tool to use that login, so AFK asks first. " +
		"AFK only reads the login, sends it to " + l.Vendor + " alone, and never stores or renews it."
}

// gatewayNew is the Config tab's row that adds a gateway.
const gatewayNew = "gateway (add)"

var gatewayNameRE = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// addGateway writes a new [gateway.<name>] with its address. The key
// reference is the next row to fill in.
func (s panelSource) addGateway(value string) (string, error) {
	f := strings.Fields(value)
	if len(f) != 2 {
		return "", errors.New("type a name and an address, for example: work https://gw.example:4000")
	}
	name, addr := f[0], f[1]
	if !gatewayNameRE.MatchString(name) {
		return "", errors.New("a gateway name is lower-case letters, digits, - or _")
	}
	u, err := url.Parse(addr)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return "", errors.New("the address must start with http:// or https://")
	}
	if u.User != nil {
		return "", errors.New("leave the password out of the address; the key goes in the key row as a reference")
	}
	paths := config.PathsFor(s.c.Home, s.getenv)
	if f, err := config.Load(paths.Config); err == nil && f.Exists {
		if _, taken := f.Config.Gateway[name]; taken {
			return "", fmt.Errorf("there is already a gateway called %s; change its rows instead", name)
		}
	}
	if _, err := config.SetKey(paths, "gateway."+name+".url", addr, false); err != nil {
		return "", err
	}
	return "gateway " + name + " added · now set gateway." + name + ".key to where its key is (for example env:" + strings.ToUpper(strings.NewReplacer("-", "_").Replace(name)) + "_KEY)", nil
}

// ConfigRemove takes a gateway out of config.toml.
func (s panelSource) ConfigRemove(_ context.Context, section string) (string, error) {
	if !strings.HasPrefix(section, "gateway.") || strings.Count(section, ".") != 1 {
		return "", fmt.Errorf("%s can't be removed here", section)
	}
	ok, err := config.RemoveSection(config.PathsFor(s.c.Home, s.getenv), section)
	if err != nil {
		return "", err
	}
	if !ok {
		return section + " is not in config.toml", nil
	}
	return section + " removed from config.toml", nil
}

// ConfigSet writes one setting to the user's config.toml, as afk config
// set does: the file's comments and order are kept, and the value is
// checked before anything is written.
func (s panelSource) ConfigSet(_ context.Context, key, value string) (string, error) {
	if key == gatewayNew {
		return s.addGateway(value)
	}
	raw := value
	if config.KeyType(key) == "bool" {
		switch value {
		case "on":
			raw = "true"
		case "off":
			raw = "false"
		}
	}
	if strings.HasPrefix(key, "harness.") && strings.HasSuffix(key, ".vendor_usage") {
		h := strings.TrimSuffix(strings.TrimPrefix(key, "harness."), ".vendor_usage")
		if !harness.HasVendorLookup(h) {
			return "", fmt.Errorf("AFK has no vendor usage lookup for %s", h)
		}
		if raw != "true" && raw != "false" {
			return "", errors.New("on or off")
		}
	}
	paths := config.PathsFor(s.c.Home, s.getenv)
	if _, err := config.SetKey(paths, key, raw, false); err != nil {
		return "", err
	}
	msg := key + " = " + value + " · saved"
	// The tab shows the setting in effect. When something else still
	// decides it, say so instead of leaving the row looking unchanged.
	repo := s.repo
	if repo == "" {
		repo = s.c.Cwd
	}
	if st, err := s.c.LoadSettings(repo); err == nil {
		eff := map[string]string{"route.prefer": st.Prefer, "route.failover": st.Failover, "permissions.default": st.Mode}
		if now, ok := eff[key]; ok && now != value {
			msg += ", but " + now + " is still in effect here (an AFK_* variable or this project's .afk/config.json decides it)"
		}
	}
	if key == "local.engines" && value != "off" && s.getenv("AFK_LOCAL_ENGINES") == "off" {
		msg += ", but AFK_LOCAL_ENGINES=off still turns them off here"
	}
	return msg, nil
}

func (s panelSource) Command(args ...string) []string {
	exe, err := os.Executable()
	if err != nil {
		exe = "afk"
	}
	return append([]string{exe}, args...)
}

const statusHelp = `Usage: afk status [--tab harnesses|bench|skills|mcp|usage|config]

Opens AFK's control panel full screen on the Usage tab (or the one --tab
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
	logos, overlay := setupLogos()
	theme := tui.NewTheme(dark).WithLogos(logos)
	p := tui.NewPanel(context.Background(), newPanelSource(core.New(), ""), theme, tab, headerInfo().Version, nil).Standalone()
	if _, err := tea.NewProgram(tui.WithKittyLogos(tui.WithOverlay(tui.PanelModel{P: p}, overlay), logos)).Run(); err != nil {
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
	v := skillsView(d, st, s.c.Home)
	if p := s.projectSkills(); p != nil {
		if err := addProjectSkills(v, p, s.c.Home); err != nil {
			v.Problems = append(v.Problems, "project skills: "+err.Error())
		}
	}
	return v, nil
}

// projectSkills is the repository's .agents/skills, if it has one.
func (s panelSource) projectSkills() *projectSkills {
	repo := s.repo
	if repo == "" {
		repo = s.c.Cwd
	}
	if repo == "" {
		return nil
	}
	return projectSkillsFor(repoRoot(repo), s.c.Harness, s.getenv)
}

// addProjectSkills adds the project's skills as rows under the central
// ones, in the same CLI columns.
func addProjectSkills(v *tui.SkillsView, p *projectSkills, home string) error {
	st, err := p.deps.env.Scan(p.deps.targets)
	if err != nil {
		return err
	}
	tilde := func(x string) string {
		if home != "" && strings.HasPrefix(x, home+string(os.PathSeparator)) {
			return "~" + strings.TrimPrefix(x, home)
		}
		return x
	}
	v.Project = tilde(st.Central)
	native := map[string]bool{}
	for _, n := range p.native {
		native[n] = true
	}
	for _, sk := range st.Skills {
		r := tui.SkillRow{Name: sk.Name, Central: sk.Central, Project: true, Scope: sk.Scope, Cells: map[string]string{}}
		if sk.Central {
			dir := filepath.Join(st.Central, sk.Name)
			r.Dir = tilde(dir)
			r.Desc, r.Files, r.Modified = skillInfo(dir)
		}
		for _, c := range v.Cols {
			switch {
			case native[c] && sk.Central:
				r.Cells[c] = "native"
			case native[c]:
				r.Cells[c] = "unmanaged"
			default:
				if cell, ok := sk.Cells[c]; ok {
					r.Cells[c] = string(cell)
				} else {
					r.Cells[c] = "unsupported"
				}
			}
		}
		if sk.Central && sk.Scope == "" {
			v.Undecided++
		}
		v.Rows = append(v.Rows, r)
	}
	v.Pending += len(st.Actions)
	v.Problems = append(v.Problems, st.Problems...)
	dirs := map[string]string{}
	for _, t := range st.Targets {
		dirs[t.Harness] = tilde(t.Dir)
	}
	for _, dr := range st.Drift {
		v.Drift = append(v.Drift, tui.SkillDrift{Skill: dr.Skill, Harness: dr.Harness, Dir: dirs[dr.Harness], Project: true,
			Modified: dr.Modified, Lines: p.deps.env.Changed(st.Targets, dr.Skill, dr.Harness)})
	}
	return nil
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
		if sk.Central {
			dir := filepath.Join(st.Central, sk.Name)
			r.Dir = tilde(dir)
			r.Desc, r.Files, r.Modified = skillInfo(dir)
		}
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

// SkillsDo runs a skills action for the tab's keys. "project:" in front
// of op runs it on the repository's own skills.
func (s panelSource) SkillsDo(ctx context.Context, op string, args ...string) (string, error) {
	d := s.skills()
	if rest, ok := strings.CutPrefix(op, "project:"); ok {
		p := s.projectSkills()
		if p == nil {
			return "", fmt.Errorf("this repository has no %s folder", projectSkillsDir)
		}
		return projectSkillsDo(p, rest, args...)
	}
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
		n := len(res.Done)
		if p := s.projectSkills(); p != nil {
			pres, err := p.sync()
			if err != nil {
				return "", err
			}
			n += len(pres.Done)
		}
		if n == 0 {
			return "Everything is in sync.", nil
		}
		return fmt.Sprintf("Synced %s.", plural(n, "change")), nil
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
	if op == "new" {
		if len(args) < 1 {
			return "", errors.New("a new skill needs a name")
		}
		desc := ""
		if len(args) > 1 {
			desc = args[1]
		}
		p, err := d.env.New(args[0], desc)
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("Created %s. Press e on it to write its steps, then s to copy it into your CLIs.", tildePath(p)), nil
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
	d := mcpDeps{env: mcpEnvFor(s.c.Home, s.getenv, st), targets: t, unsupported: u, getenv: s.getenv}
	user, he := d, s.c.Harness
	d.project = func() *projectMCP {
		if repo == "" {
			return nil
		}
		return projectMCPFor(repoRoot(repo), he, s.getenv, user)
	}
	return d, nil
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
	v := mcpView(d, st, s.c.Home, time.Now())
	if found, err := d.env.Found(d.targets); err == nil {
		for _, f := range found {
			v.Found = append(v.Found, tui.MCPFound{Name: f.Name, In: f.In, Where: f.Where(), Why: f.Why, Left: f.Left, Differs: f.Differs})
		}
	}
	if p := d.project(); p != nil {
		if err := addProjectMCP(v, p, s.c.Home, time.Now()); err != nil {
			v.Problems = append(v.Problems, "project servers: "+err.Error())
		}
	}
	return v, nil
}

// addProjectMCP adds the project's servers as rows under mcp.toml's, in
// the same CLI columns.
func addProjectMCP(v *tui.MCPView, p *projectMCP, home string, now time.Time) error {
	st, err := p.deps.env.Scan(p.deps.targets)
	if err != nil {
		return err
	}
	pv := mcpView(p.deps, st, home, now)
	v.Project = pv.Source
	native := map[string]bool{}
	for _, n := range p.native {
		native[n] = true
	}
	for _, r := range pv.Rows {
		r.Project = true
		for _, sr := range st.Rows {
			if sr.Name == r.Name {
				r.Scope = sr.Scope
			}
		}
		if r.Notes == nil {
			r.Notes = map[string]string{}
		}
		for _, c := range v.Cols {
			switch {
			case native[c] && r.Listed:
				r.Cells[c] = "native"
			case native[c]:
				r.Cells[c] = "unmanaged"
			case r.Cells[c] == "":
				r.Cells[c] = "unsupported"
				r.Notes[c] = p.notes[c]
				if r.Notes[c] == "" {
					r.Notes[c] = c + " has no project MCP file AFK knows"
				}
			}
		}
		if r.Listed && r.Scope == "" {
			v.Undecided++
		}
		v.Rows = append(v.Rows, r)
	}
	for _, dr := range pv.Drift {
		dr.Project = true
		v.Drift = append(v.Drift, dr)
	}
	v.Pending += pv.Pending
	for _, pr := range pv.Problems {
		v.Problems = append(v.Problems, "skipped "+pr)
	}
	return nil
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
	byName := map[string]mcp.Server{}
	for _, sv := range st.Servers {
		byName[sv.Name] = sv
	}
	files := map[string]string{}
	for _, t := range st.Targets {
		files[t.Harness] = tilde(t.File)
	}
	for _, r := range st.Rows {
		sv := byName[r.Name]
		row := tui.MCPRow{Name: r.Name, Via: sv.Via, Listed: r.Listed, Tools: -1, Status: "untested", Cells: map[string]string{}, Notes: r.Notes,
			Token: sv.BearerEnv, Env: sv.Env, Files: files}
		if sv.Kind == "http" {
			row.Where = sv.URL
		} else if sv.Command != "" {
			row.Where = strings.TrimSpace(sv.Command + " " + strings.Join(sv.Args, " "))
		}
		if tr, ok := st.Tested[r.Name]; ok && !tr.At.IsZero() {
			row.Status, row.Tested, row.TestError = "down", ago(now.Sub(tr.At)), tr.Error
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

// projectOnly is d working on the repository's .mcp.json alone, so a
// project server is found even when mcp.toml has one of the same name.
func projectOnly(d mcpDeps) (mcpDeps, error) {
	p := d.project()
	if p == nil {
		return d, fmt.Errorf("this repository has no %s", mcp.ProjectFile)
	}
	return mcpDeps{env: p.deps.env, targets: p.deps.targets, getenv: d.getenv}, nil
}

// MCPTools lists a server's tools for the MCP tab's ↵. "project:" in
// front of the name is the repository's own server.
func (s panelSource) MCPTools(ctx context.Context, server string) ([]tui.MCPTool, error) {
	d, err := s.mcp()
	if err != nil {
		return nil, err
	}
	if name, ok := strings.CutPrefix(server, "project:"); ok {
		if d, err = projectOnly(d); err != nil {
			return nil, err
		}
		server = name
	}
	tools, err := testMCPServer(ctx, d, server)
	if err != nil {
		return nil, err
	}
	out := make([]tui.MCPTool, 0, len(tools))
	for _, t := range tools {
		out = append(out, tui.MCPTool{Name: t.Name, Description: t.Description})
	}
	return out, nil
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
	if rest, ok := strings.CutPrefix(op, "project:"); ok && rest != "test" {
		p := d.project()
		if p == nil {
			return "", fmt.Errorf("this repository has no %s", mcp.ProjectFile)
		}
		return projectMCPDo(p, rest, args...)
	} else if ok {
		if d, err = projectOnly(d); err != nil {
			return "", err
		}
		op = rest
	}
	switch op {
	case "import":
		done, err := d.env.Import(d.targets, args)
		if len(done) > 0 {
			msg := fmt.Sprintf("Added %s to mcp.toml. s gives them to your other CLIs.", strings.Join(done, ", "))
			if err != nil {
				msg += " " + err.Error()
			}
			return msg, nil
		}
		if err != nil {
			return "", err
		}
		return "Nothing to import.", nil
	case "sync":
		res, err := d.env.Sync(d.targets)
		if err != nil {
			return "", err
		}
		n := len(res.Done)
		if p := d.project(); p != nil {
			pres, err := p.sync()
			if err != nil {
				return "", err
			}
			n += len(pres.Done)
		}
		if n == 0 {
			return "Everything is in sync.", nil
		}
		return fmt.Sprintf("Synced %s.", plural(n, "change")), nil
	case "test":
		if len(args) != 1 {
			return "", fmt.Errorf("mcp test needs a server")
		}
		tools, err := testMCPServer(ctx, d, args[0])
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%s is up: %s.", args[0], plural(len(tools), "tool")), nil
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
	if op == "add" {
		if len(args) != 1 {
			return "", errors.New("a new server needs a name and where it is")
		}
		name, err := addMCPServer(d, args[0])
		if err != nil {
			return "", err
		}
		return fmt.Sprintf("%s is in %s. Press s to add it to your CLIs, t to test it.", name, tildePath(d.env.Config)), nil
	}
	return "", fmt.Errorf("unknown mcp action %q", op)
}

// extraText is a plan's usage beyond its windows, as its CLI reported it:
// "extra usage: credits 56656.97". "" when it reported none.
func extraText(x *harness.Extra) string {
	switch {
	case x == nil:
		return ""
	case !x.Enabled:
		return "extra usage: off"
	case x.Unlimited:
		return "extra usage: unlimited"
	case x.Limit != "":
		spent := x.Spent
		if spent == "" {
			spent = "an unknown amount"
		}
		t := "extra usage: " + spent + " of " + x.Limit
		if x.Currency != "" {
			t += " " + x.Currency
		}
		t += " used"
		if x.Balance != "" {
			t += ", credits " + balanceText(x.Balance)
		}
		return t
	case x.Balance != "":
		return "extra usage: credits " + balanceText(x.Balance)
	}
	return "extra usage: on"
}

// vendorOf names who a CLI's vendor usage lookup asks ("Anthropic").
func vendorOf(h string) string {
	for _, l := range harness.VendorLookups() {
		if l.Harness == h {
			return l.Vendor
		}
	}
	return "the vendor"
}

// balanceText is a credit balance for people: a plain number is shown to
// two places ("56656.9766350000" is "56656.98"); anything else as it came.
func balanceText(b string) string {
	if f, err := strconv.ParseFloat(b, 64); err == nil && !strings.ContainsAny(b, "eE") {
		return strconv.FormatFloat(f, 'f', 2, 64)
	}
	return b
}

// paceText says where a plan's window is heading at the rate so far, and
// whether route.pacing leans toward it. "" when AFK has no measured pace.
func paceText(pc *router.Pacing) (string, bool) {
	if pc == nil {
		return "", false
	}
	switch {
	case pc.RunsOutAt != nil:
		if t, err := time.Parse(time.RFC3339, *pc.RunsOutAt); err == nil {
			return "may run out " + t.Local().Format("Mon 15:04") + ", before the reset", false
		}
		return "may run out before the reset", false
	case pc.UnusedAtResetPct != nil && *pc.UnusedAtResetPct >= 5:
		txt := fmt.Sprintf("~%.0f%% may go unused", *pc.UnusedAtResetPct)
		if pc.Adjustment > 0 {
			return txt + ", so AFK leans to it", true
		}
		return txt, false
	}
	return "on track", false
}
