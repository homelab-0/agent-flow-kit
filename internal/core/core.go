// Package core is AFK's routing and launch engine in Go: it decides the
// route for a task (internal/router), builds the launch plan for the
// chosen CLI, reports pool usage, and runs one-shot answers (-p).
package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/homelab-0/agent-flow-kit/internal/config"
	"github.com/homelab-0/agent-flow-kit/internal/engine"
	"github.com/homelab-0/agent-flow-kit/internal/harness"
	"github.com/homelab-0/agent-flow-kit/internal/router"
	"github.com/homelab-0/agent-flow-kit/internal/runrec"
)

// Routable are the CLIs AFK routes to and launches, in the order the bash
// engine lists them.
var Routable = []string{"claude", "codex", "opencode", "grok", "agy", "pi"}

// Core is the Go engine for one machine.
type Core struct {
	Home   string
	Getenv func(string) string
	// Harness is how CLIs are found.
	Harness harness.Env
	// Cwd is where a launched CLI starts.
	Cwd string
	// Live turns on the network probes (Claude usage, gateway).
	Live bool
	// Now is the clock (tests).
	Now func() time.Time
	// Installed overrides the installed-and-answering check (tests).
	Installed func(string) bool
	// Environ is the environment a launch starts from (os.Environ).
	Environ func() []string
	// CodexLogin reports how Codex is signed in (tests; nil asks Codex's
	// own status command when Live).
	CodexLogin func(ctx context.Context) string
	// SignIn reports whether a CLI's own status command says it is signed
	// in (tests; nil asks the CLI when Live).
	SignIn func(ctx context.Context, harness string) (signedIn, known bool)

	// Accounts asks a CLI what this account has (tests; nil asks the CLI
	// through its module in internal/harness).
	Accounts func(ctx context.Context, harness string) (harness.Account, bool)

	acctMu   sync.Mutex
	acctMemo map[string]accountEntry
	signMu   sync.Mutex
	signMemo map[string]signAnswer
	// NoTerminal says afk's output is not a terminal. A CLI started that
	// way skips its own "trust this folder?" question, as a one-shot run
	// does.
	NoTerminal bool
	// Headless runs a print-mode CLI (tests; nil runs it for real).
	Headless Headless
}

// New is the engine for this machine.
func New() *Core {
	he := harness.HostEnv()
	cwd, _ := os.Getwd()
	return &Core{Home: he.Home, Getenv: os.Getenv, Harness: he, Cwd: cwd, Live: true, Now: time.Now, Environ: os.Environ}
}

// codexLoginMode is how the pool probe learns whether Codex uses the
// ChatGPT plan or an API key, without opening Codex's auth.json.
func (c *Core) codexLoginMode() func(ctx context.Context) string {
	if c.CodexLogin != nil {
		return c.CodexLogin
	}
	if !c.Live {
		return nil
	}
	return func(ctx context.Context) string { return harness.CodexLoginMode(ctx, c.Harness) }
}

// signedIn is how the pool probe asks a CLI's own status command whether
// it is signed in. An answer is kept for half a minute, so the few probes
// one afk makes at startup ask each CLI once.
func (c *Core) signedIn() func(ctx context.Context, h string) (bool, bool) {
	if c.SignIn != nil {
		return c.SignIn
	}
	if !c.Live {
		return nil
	}
	return func(ctx context.Context, h string) (bool, bool) {
		c.signMu.Lock()
		if hit, ok := c.signMemo[h]; ok && time.Since(hit.at) < 30*time.Second {
			c.signMu.Unlock()
			return hit.in, hit.known
		}
		c.signMu.Unlock()
		a, ok := harness.Lookup(h)
		if !ok {
			return false, false
		}
		st, known := harness.StatusSignIn(ctx, c.Harness, a, 5*time.Second)
		if ctx.Err() == nil {
			c.signMu.Lock()
			if c.signMemo == nil {
				c.signMemo = map[string]signAnswer{}
			}
			c.signMemo[h] = signAnswer{in: st == harness.AuthOK, known: known, at: time.Now()}
			c.signMu.Unlock()
		}
		return st == harness.AuthOK, known
	}
}

type signAnswer struct {
	in, known bool
	at        time.Time
}

func (c *Core) getenv(k string) string {
	if c.Getenv == nil {
		return ""
	}
	return c.Getenv(k)
}

func (c *Core) now() time.Time {
	if c.Now == nil {
		return time.Now()
	}
	return c.Now()
}

// Settings are the effective settings: see config.Resolve for where each
// comes from.
type Settings = config.Settings

// LoadSettings reads the settings for a project directory: the
// environment, the project's .afk/config.json, config.toml (or, while it
// doesn't exist, ~/.config/afk/router.json), then defaults. A config.toml
// that doesn't validate is an error naming the file, line and key.
func (c *Core) LoadSettings(repo string) (Settings, error) {
	return config.Resolve(config.Env{Home: c.Home, Getenv: c.getenv, Repo: repo})
}

// InstalledRoutable lists the routable CLIs found on this machine.
func (c *Core) InstalledRoutable() []string {
	var out []string
	disabled := map[string]bool{}
	if s, err := c.LoadSettings(""); err == nil {
		disabled = s.Disabled
	}
	for _, h := range Routable {
		a, ok := harness.Lookup(h)
		if ok && !disabled[h] && harness.Locate(c.Harness, a) != "" {
			out = append(out, h)
		}
	}
	return out
}

// state is what one routing session reads once: catalog, pools, models.
type state struct {
	r        *router.Router
	settings Settings
}

func (c *Core) load(ctx context.Context, repo string) (*state, error) {
	cat, err := router.LoadCatalog(c.Home, c.getenv)
	if err != nil {
		return nil, err
	}
	s, err := c.LoadSettings(repo)
	if err != nil {
		return nil, err
	}
	installed := c.Installed
	if installed == nil {
		installed = router.VerifyBinaries(ctx, c.Harness, c.getenv)
	}
	probe := router.ProbePools(ctx, cat, c.probeEnv(s, installed))
	r := &router.Router{Catalog: cat, Probe: probe, Discovered: c.discovered(), Pacing: s.Pacing}
	if s.Learn {
		r.Outcomes = Outcomes(runrec.Load(runrec.DirFor(c.Home, c.getenv), c.now().Add(-OutcomeMaxAge)))
	}
	return &state{r: r, settings: s}, nil
}

// probeEnv is what the pool probe reads, for these settings.
func (c *Core) probeEnv(s config.Settings, installed func(string) bool) router.ProbeEnv {
	return router.ProbeEnv{
		Home: c.Home, Getenv: c.getenv, Now: c.now(), GatewayURL: s.GatewayURL,
		LocalURLs: s.LocalURLs, GPU: gpuName(s.LocalGPU),
		Installed: installed, Live: c.Live, CodexLoginMode: c.codexLoginMode(), SignedIn: c.signedIn(), Account: c.account(s.VendorUsage),
	}
}

// OutcomeMaxAge is how far back ratings count: models and CLIs change.
const OutcomeMaxAge = 180 * 24 * time.Hour

// OutcomesPerRoute is how many of a route's newest ratings count.
const OutcomesPerRoute = 30

// Outcomes tallies rated run records (newest first) by CLI, model and
// task class. Unrated runs, and runs with no task class, don't count. A
// "wrong pick" on a route you pinned yourself says nothing about the
// router, so it is left out.
func Outcomes(recs []runrec.Record) map[router.OutcomeKey]router.OutcomeStats {
	out := map[router.OutcomeKey]router.OutcomeStats{}
	for _, rec := range recs {
		if rec.Outcome == nil || rec.Route.TaskClass == "" || rec.Route.Harness == "" {
			continue
		}
		o := *rec.Outcome
		if o == runrec.WrongPick && rec.Route.Pinned {
			continue
		}
		k := router.OutcomeKeyFor(rec.Route.Harness, rec.Route.CanonicalModel, rec.Route.Model, rec.Route.TaskClass)
		st := out[k]
		if st.Runs() >= OutcomesPerRoute {
			continue
		}
		switch o {
		case runrec.Solved:
			st.Solved++
		case runrec.Partly:
			st.Partly++
		case runrec.WrongPick:
			st.Wrong++
		default:
			continue
		}
		out[k] = st
	}
	return out
}

// DiscoveredMaxAge is how long ~/.config/afk/discovered-models.json is
// trusted. Only the old bash engine's model sync wrote it, and nothing
// refreshes it now, so an old copy would keep offering models a CLI may
// no longer have.
const DiscoveredMaxAge = 7 * 24 * time.Hour

// discovered reads the models the CLIs reported, if any: a file named by
// AFK_DISCOVERED_MODELS_FILE always, ~/.config/afk/discovered-models.json
// only while it is younger than DiscoveredMaxAge.
func (c *Core) discovered() []router.DiscoveredModel {
	p, explicit := c.getenv("AFK_DISCOVERED_MODELS_FILE"), true
	if p == "" {
		p, explicit = c.discoveredPath(), false
	}
	if !explicit && c.discoveredStale() {
		return nil
	}
	var d struct {
		Models []router.DiscoveredModel `json:"models"`
	}
	if b, err := os.ReadFile(p); err == nil {
		_ = json.Unmarshal(b, &d)
	}
	return d.Models
}

func (c *Core) discoveredPath() string {
	return filepath.Join(c.Home, ".config", "afk", "discovered-models.json")
}

func (c *Core) discoveredStale() bool {
	fi, err := os.Stat(c.discoveredPath())
	return err == nil && c.now().Sub(fi.ModTime()) > DiscoveredMaxAge
}

// DiscoveredWarning is a line for the person when an old
// discovered-models.json is being ignored, or "".
func (c *Core) DiscoveredWarning() string {
	if c.getenv("AFK_DISCOVERED_MODELS_FILE") != "" || !c.discoveredStale() {
		return ""
	}
	return c.discoveredPath() + " is more than 7 days old and nothing updates it any more, so it is ignored; delete it to drop this note"
}

// route asks the router for one task, limited to the given CLIs. When no
// route qualifies, ok is false: the router's fallback carries made-up
// numbers (score 85, full headroom), so it is never launched or shown as
// a pick. A pool limits it further to routes that pool serves; "" allows
// any.
func (st *state) route(task, prefer string, only []string, pool string) (router.Route, bool, error) {
	return st.routeIn(task, prefer, router.Input{OnlyHarnesses: only, OnlyPool: pool})
}

// routeIn is route with the limits in lim (OnlyHarnesses, OnlyPool,
// ExcludePools, OnlyEngineURL).
func (st *state) routeIn(task, prefer string, lim router.Input) (router.Route, bool, error) {
	stage, risk, err := router.TaskRoute(task, prefer)
	if err != nil {
		return router.Route{}, false, err
	}
	pf := st.settings.PreferFree || prefer == "cheap" || task == "quick"
	r := st.r.Select(router.Input{
		Stage: stage, Risk: risk, Round: 1, Surfaces: []string{"code"},
		OnlyHarnesses: lim.OnlyHarnesses, OnlyPool: lim.OnlyPool, ExcludePools: lim.ExcludePools, OnlyEngineURL: lim.OnlyEngineURL,
		GatewayURL: st.settings.GatewayURL, AllowMetered: st.settings.AllowMetered,
		PreferFree: pf, AllowFreeReviewers: st.settings.AllowFreeReviewers, SecurityModels: st.settings.SecurityModels,
	})
	if r.IsFallback() {
		return r, false, nil
	}
	st.labelGateway(&r)
	return r, true, nil
}

// labelGateway names the gateway a gateway route goes through, and the
// engine and host behind it, from your config.
func (st *state) labelGateway(r *router.Route) {
	if !strings.HasSuffix(r.LaunchClass, "-gateway") || r.LitellmBaseURL == nil {
		return
	}
	if name, g, ok := st.settings.GatewayFor(*r.LitellmBaseURL); ok {
		r.GatewayName, r.GatewayKind, r.Engine, r.EngineHost = name, g.Kind, g.Engine, g.Host
		return
	}
	if *r.LitellmBaseURL == st.settings.GatewayURL {
		r.GatewayName = st.settings.GatewayName
	}
}

// UsageError is a request that can't be routed as asked (exit 2).
type UsageError struct{ Msg string }

func (e *UsageError) Error() string { return e.Msg }

// NotInstalledError is a CLI that is not here (exit 3).
type NotInstalledError struct{ Msg string }

func (e *NotInstalledError) Error() string { return e.Msg }

// NoRouteError is a task nothing here can do (exit 4).
type NoRouteError struct{ Msg string }

func (e *NoRouteError) Error() string { return e.Msg }

// decision is a routed request: the route chosen and what it was chosen
// from, so the alternatives (Explain) or the next route (Print) can be
// asked for the same way.
type decision struct {
	st        *state
	repo      string
	task      string
	prefer    string
	guessed   bool
	installed []string
	// pinH and pinM are the CLI and model after --model was resolved.
	pinH, pinM string
	// list is the CLIs the route may use.
	list   []string
	effort string
	// mode is the permission mode asked for, and where it came from.
	mode, modeSource string
	// choice is the route: a router.Route, or the pinned route's map.
	choice any
}

// decide routes a prompt: checks the flags, finds the installed CLIs and
// asks the router.
func (c *Core) decide(ctx context.Context, f engine.RouteFlags, prompt string) (*decision, error) {
	repo := f.Repo
	if repo == "" {
		repo = c.Cwd
	}
	settings, err := c.LoadSettings(repo)
	if err != nil {
		return nil, err
	}
	// --prefer wins over the project's and your config's route.prefer.
	prefer := f.Prefer
	if prefer == "" {
		prefer = settings.Prefer
	}
	if prefer == "" {
		prefer = "balanced"
	}
	if !contains(router.Prefers, prefer) {
		return nil, &UsageError{"--prefer must be balanced, cheap or best"}
	}
	switch f.Effort {
	case "", "low", "medium", "high":
	default:
		return nil, &UsageError{"--effort must be low, medium or high"}
	}
	task, guessed := f.Task, false
	if task == "" {
		task, guessed = router.GuessTask(prompt), true
	}
	if _, _, err := router.TaskRoute(task, prefer); err != nil {
		return nil, &UsageError{"unknown --task " + task}
	}
	installed := c.InstalledRoutable()
	if len(installed) == 0 {
		return nil, &NotInstalledError{"none of " + strings.Join(Routable, " ") + " is installed"}
	}
	pinH, pinM := f.Harness, f.Model
	if pinH != "" && !contains(installed, pinH) {
		return nil, &NotInstalledError{fmt.Sprintf("%s is not installed here (found: %s)", pinH, strings.Join(installed, ","))}
	}
	cands := installed
	if pinH != "" {
		cands = []string{pinH}
	}
	engine.ReportProgress(ctx, engine.Progress{Kind: "start", Task: task, Guessed: guessed, Prefer: prefer, Harnesses: cands})
	st, err := c.load(ctx, repo)
	if err != nil {
		return nil, err
	}
	if pinM != "" && pinH == "" {
		served := st.r.ServedBy(pinM, installed, st.settings.AllowMetered)
		switch len(served) {
		case 0:
			return nil, &UsageError{fmt.Sprintf("no installed CLI is known to serve %s; name one with --harness", pinM)}
		case 1:
			for h, m := range served {
				pinH, pinM = h, m
			}
		default:
			var hs []string
			for _, h := range installed {
				if _, ok := served[h]; ok {
					hs = append(hs, h)
				}
			}
			return nil, &UsageError{fmt.Sprintf("%s is served by %s; choose one with --harness", pinM, strings.Join(hs, " and "))}
		}
	}
	mode, modeSource, err := c.permMode(settings, f.Perm, task)
	if err != nil {
		return nil, err
	}
	d := &decision{
		st: st, repo: repo, task: task, prefer: prefer, guessed: guessed, installed: installed,
		pinH: pinH, pinM: pinM, list: installed, effort: f.Effort, mode: mode, modeSource: modeSource,
	}
	if pinH != "" {
		d.list = []string{pinH}
	}
	if pinH != "" && pinM != "" {
		d.choice = map[string]any{
			"harness": pinH, "model": pinM, "effort": nilIfEmpty(f.Effort), "entitlement_pool": nil,
			"reason": "pinned by --harness and --model", "pinned": true,
		}
		return d, nil
	}
	r, ok, err := st.route(task, prefer, d.list, "")
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, &NoRouteError{"the router found no usable model for this task on " + strings.Join(d.list, ",") + signInHint(st.r.Probe, d.list) + poolHint(st.r, d.list, st.settings.GatewayURL != "")}
	}
	if f.Effort != "" {
		r.Effort = f.Effort
	}
	d.choice = r
	return d, nil
}

// Explain decides the route for a prompt and, unless a CLI is pinned, the
// best route on every installed CLI.
func (c *Core) Explain(ctx context.Context, f engine.RouteFlags, prompt string) (*engine.Explain, error) {
	d, err := c.decide(ctx, f, prompt)
	if err != nil {
		return nil, err
	}
	alts := []router.Route{}
	if d.pinH == "" {
		// One row per CLI on its own login, then the gateway and each
		// local engine as rows of their own, so a free route is shown
		// beside the plan routes rather than hiding them.
		type row struct {
			key string
			lim router.Input
		}
		offPlan := []string{gatewayPool, router.LocalPool}
		var rows []row
		for _, h := range d.installed {
			rows = append(rows, row{h, router.Input{OnlyHarnesses: []string{h}, ExcludePools: offPlan}})
		}
		var extra []string
		if d.st.r.Probe != nil && d.st.r.Probe.Harnesses["litellm_gateway"].Online && contains(d.installed, "claude") {
			rows = append(rows, row{"gateway", router.Input{OnlyHarnesses: []string{"claude"}, OnlyPool: gatewayPool}})
			extra = append(extra, "gateway")
		}
		if d.st.r.Probe != nil && contains(d.installed, "claude") {
			for _, le := range d.st.r.Probe.Local {
				k := localKey(le, extra)
				rows = append(rows, row{k, router.Input{OnlyHarnesses: []string{"claude"}, OnlyPool: router.LocalPool, OnlyEngineURL: le.URL}})
				extra = append(extra, k)
			}
		}
		if len(extra) > 0 {
			engine.ReportProgress(ctx, engine.Progress{Kind: "add", Harnesses: extra})
		}
		for _, rw := range rows {
			r, ok, err := d.st.routeIn(d.task, d.prefer, rw.lim)
			if err != nil || !ok {
				engine.ReportProgress(ctx, engine.Progress{Kind: "skip", Harness: rw.key})
				continue
			}
			if f.Effort != "" && len(r.SupportedEfforts) > 0 {
				r.Effort = f.Effort
			}
			alts = append(alts, r)
			reportRoute(ctx, rw.key, r)
		}
		sortByScore(alts)
	}
	doc := map[string]any{
		"schema": engine.SchemaExplain, "task": d.task, "task_guessed": d.guessed, "prefer": d.prefer,
		"choice": d.choice, "by_harness": alts,
		"mode": d.mode, "mode_source": d.modeSource, "mode_by_harness": modesFor(d.installed, d.mode),
	}
	b, err := json.Marshal(doc)
	if err != nil {
		return nil, err
	}
	return engine.ParseExplain(b)
}

// Pools reports plan pool usage, for the receipt.
func (c *Core) Pools(ctx context.Context) (*engine.Pools, error) {
	p, err := c.Probe(ctx)
	if err != nil {
		return nil, err
	}
	p.Schema = engine.SchemaPools
	b, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	return engine.ParsePools(b)
}

// Probe is the state of every plan pool now, as routing sees it.
func (c *Core) Probe(ctx context.Context) (*router.Probe, error) {
	cat, err := router.LoadCatalog(c.Home, c.getenv)
	if err != nil {
		return nil, err
	}
	s, err := c.LoadSettings(c.Cwd)
	if err != nil {
		return nil, err
	}
	installed := c.Installed
	if installed == nil {
		installed = router.VerifyBinaries(ctx, c.Harness, c.getenv)
	}
	return router.ProbePools(ctx, cat, c.probeEnv(s, installed)), nil
}

// gatewayPool is the pool the model gateway's routes draw on.
const gatewayPool = "litellm-local"

// localKey names a local engine's row on the routing screen: the engine,
// or its address when two engines share a name.
func localKey(le router.LocalEngine, taken []string) string {
	k := le.Engine
	if k == "" {
		k = "local"
	}
	if contains(taken, k) {
		k = le.URL
	}
	return k
}

// gpuName names this machine's GPU: the label from config, else the first
// one nvidia-smi lists, shortened ("NVIDIA GeForce RTX 5090" is "RTX
// 5090"). "" when there is none it can tell.
func gpuName(label string) func(context.Context) string {
	return func(ctx context.Context) string {
		if label != "" {
			return label
		}
		ctx, cancel := context.WithTimeout(ctx, time.Second)
		defer cancel()
		out, err := exec.CommandContext(ctx, "nvidia-smi", "--query-gpu=name", "--format=csv,noheader").Output()
		if err != nil {
			return ""
		}
		return shortGPU(string(out))
	}
}

func shortGPU(s string) string {
	s, _, _ = strings.Cut(strings.TrimSpace(s), "\n")
	s = strings.TrimSpace(s)
	for _, p := range []string{"NVIDIA ", "GeForce "} {
		s = strings.TrimPrefix(s, p)
	}
	if len(s) > 40 || strings.ContainsAny(s, "\x00\x1b\r") {
		return ""
	}
	return s
}

// reportRoute passes a scored route to the routing screen, in the shape
// the explain payload has.
func reportRoute(ctx context.Context, h string, r router.Route) {
	b, err := json.Marshal(r)
	if err != nil {
		return
	}
	var er engine.Route
	if json.Unmarshal(b, &er) != nil {
		return
	}
	engine.ReportProgress(ctx, engine.Progress{Kind: "route", Harness: h, Route: &er})
}

func sortByScore(rs []router.Route) {
	for i := 1; i < len(rs); i++ {
		for j := i; j > 0 && rs[j].EffectiveScore > rs[j-1].EffectiveScore; j-- {
			rs[j], rs[j-1] = rs[j-1], rs[j]
		}
	}
}

func nilIfEmpty(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// ExitCode maps an engine error to the exit code the bash engine uses.
func ExitCode(err error) int {
	var ue *UsageError
	var ni *NotInstalledError
	var nr *NoRouteError
	var pe *engine.PlanError
	switch {
	case err == nil:
		return 0
	case errors.As(err, &ue):
		return 2
	case errors.As(err, &ni):
		return 3
	case errors.As(err, &nr), errors.As(err, &pe):
		return 4
	}
	return 1
}

// permMode is the permission mode for a run: --mode or --yolo, else
// permissions.task.<kind>, else permissions.default, else ask, made
// stricter (never looser) by the project's permissions.default. yolo is
// refused outside a trusted git repository.
func (c *Core) permMode(s Settings, flag, task string) (mode, source string, err error) {
	if flag != "" {
		mode, source = flag, "flag"
	} else {
		base, src := s.TaskModes[task], "permissions.task."+task
		if base == "" {
			base, src = s.DefaultMode, "permissions.default"
		}
		if base == "" {
			base, src = "ask", "default"
		}
		mode, source = s.ModeFor(task), src
		if mode != base {
			source = "project"
		}
	}
	if harness.ModeRank(mode) < 0 {
		return "", "", &UsageError{"--mode must be read-only, ask, edits, auto or yolo"}
	}
	if mode == "yolo" {
		if err := c.checkYoloWith(s); err != nil {
			return "", "", err
		}
	}
	return mode, source, nil
}

// checkYolo refuses yolo outside a trusted git repository, reading the
// settings as they are now.
func (c *Core) checkYolo() error {
	s, err := c.LoadSettings(c.cwd())
	if err != nil {
		return err
	}
	return c.checkYoloWith(s)
}

func (c *Core) checkYoloWith(s Settings) error {
	if err := config.CheckYolo(s, c.Home, c.cwd()); err != nil {
		return &UsageError{err.Error()}
	}
	return nil
}

func (c *Core) cwd() string {
	if c.Cwd != "" {
		return c.Cwd
	}
	d, _ := os.Getwd()
	return d
}

// modesFor is what each CLI runs a mode as.
func modesFor(clis []string, mode string) map[string]engine.ModeInfo {
	out := map[string]engine.ModeInfo{}
	for _, h := range clis {
		m, ok := harness.ManifestFor(h)
		if !ok {
			continue
		}
		_, ran, note, ok := m.ModeFlags(mode, false)
		if !ok {
			out[h] = engine.ModeInfo{Mode: "", Note: note}
			continue
		}
		out[h] = engine.ModeInfo{Mode: ran, Note: note}
	}
	return out
}

// signInHint says which of the CLIs asked for needs a sign-in, with the
// command, when that is why nothing could be routed.
// poolHint says, for each pool that the given CLIs draw on and that the
// router set aside, why and what to do about it. A sign-in failure is left
// to signInHint.
func poolHint(r *router.Router, list []string, gateway bool) string {
	if r == nil || r.Probe == nil || r.Catalog == nil {
		return ""
	}
	var ids []string
	seen := map[string]bool{}
	for _, c := range r.Catalog.Candidates {
		// Gateway routes count only when a gateway is set up.
		if !gateway && strings.HasSuffix(c.LaunchClass, "-gateway") {
			continue
		}
		if c.EntitlementPool != "" && contains(list, c.Harness) && !seen[c.EntitlementPool] {
			seen[c.EntitlementPool] = true
			ids = append(ids, c.EntitlementPool)
		}
	}
	sort.Strings(ids)
	var parts []string
	for _, id := range ids {
		p, ok := r.Probe.Pools[id]
		if !ok {
			continue
		}
		var msg string
		switch p.State {
		case "exhausted":
			msg = id + " is exhausted"
			if p.UsedPct != nil {
				msg += fmt.Sprintf(" (%.0f%% used", *p.UsedPct)
				if p.QuotaSource != "" {
					msg += ", " + p.QuotaSource
				}
				msg += ")"
			}
			if p.ResetsAt != nil && *p.ResetsAt != "" {
				msg += ", resets " + *p.ResetsAt
			}
		case "offline":
			msg = id + " is offline"
		default:
			continue
		}
		if p.DegradedReason != nil && *p.DegradedReason != "" {
			msg += fmt.Sprintf(": a run failed with %q; if that was wrong, run: afk pools clear %s", cutHint(*p.DegradedReason, 80), id)
		}
		parts = append(parts, msg)
	}
	if len(parts) == 0 {
		return ""
	}
	return "; " + strings.Join(parts, "; ") + ". To use a set-aside plan anyway, pin it with --harness and --model"
}

func cutHint(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8.RuneStart(s[n]) {
		n--
	}
	return s[:n] + "…"
}

func signInHint(p *router.Probe, list []string) string {
	if p == nil {
		return ""
	}
	var parts []string
	seen := map[string]bool{}
	for _, a := range p.AuthAlerts {
		m, ok := a.(map[string]any)
		if !ok {
			continue
		}
		cmd, _ := m["reauth_command"].(string)
		var hs []string
		switch v := m["harnesses"].(type) {
		case []string:
			hs = v
		case []any:
			for _, x := range v {
				if s, ok := x.(string); ok {
					hs = append(hs, s)
				}
			}
		}
		for _, h := range hs {
			if contains(list, h) && !seen[h] {
				seen[h] = true
				msg := h + " needs sign-in"
				if cmd != "" {
					msg += " (run: " + cmd + ")"
				}
				parts = append(parts, msg)
			}
		}
	}
	if len(parts) == 0 {
		return ""
	}
	return "; " + strings.Join(parts, "; ")
}

// Router loads what routing reads (catalog, pool probe, ratings) and the
// settings of a project ("" for the current directory), for views such as
// the control panel's.
func (c *Core) Router(ctx context.Context, repo string) (*router.Router, Settings, error) {
	if repo == "" {
		repo = c.Cwd
	}
	st, err := c.load(ctx, repo)
	if err != nil {
		return nil, Settings{}, err
	}
	return st.r, st.settings, nil
}
