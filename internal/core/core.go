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
	"path/filepath"
	"strings"
	"time"

	"github.com/jlengelbrecht/agent-flow-kit/internal/config"
	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
	"github.com/jlengelbrecht/agent-flow-kit/internal/harness"
	"github.com/jlengelbrecht/agent-flow-kit/internal/router"
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
	probe := router.ProbePools(ctx, cat, router.ProbeEnv{
		Home: c.Home, Getenv: c.getenv, Now: c.now(), GatewayURL: s.GatewayURL,
		Installed: installed, Live: c.Live, CodexLoginMode: c.codexLoginMode(),
	})
	return &state{r: &router.Router{Catalog: cat, Probe: probe, Discovered: c.discovered()}, settings: s}, nil
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

// route asks the router for one task, limited to the given CLIs. A
// fallback that names a CLI outside them means nothing here can do the
// task (ok is false).
func (st *state) route(task, prefer string, only []string) (router.Route, bool, error) {
	stage, risk, err := router.TaskRoute(task, prefer)
	if err != nil {
		return router.Route{}, false, err
	}
	pf := st.settings.PreferFree || prefer == "cheap" || task == "quick"
	r := st.r.Select(router.Input{
		Stage: stage, Risk: risk, Round: 1, Surfaces: []string{"code"},
		OnlyHarnesses: only, GatewayURL: st.settings.GatewayURL, AllowMetered: st.settings.AllowMetered,
		PreferFree: pf, AllowFreeReviewers: st.settings.AllowFreeReviewers, SecurityModels: st.settings.SecurityModels,
	})
	if r.IsFallback() && !contains(only, r.Harness) {
		return r, false, nil
	}
	return r, true, nil
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
	r, ok, err := st.route(task, prefer, d.list)
	if err != nil {
		return nil, err
	}
	if !ok {
		return nil, &NoRouteError{"the router found no usable model for this task on " + strings.Join(d.list, ",") + signInHint(st.r.Probe, d.list)}
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
		for _, h := range d.installed {
			r, ok, err := d.st.route(d.task, d.prefer, []string{h})
			if err != nil || !ok {
				continue
			}
			if f.Effort != "" {
				r.Effort = f.Effort
			}
			alts = append(alts, r)
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
	p := router.ProbePools(ctx, cat, router.ProbeEnv{
		Home: c.Home, Getenv: c.getenv, Now: c.now(), GatewayURL: s.GatewayURL, Installed: installed, Live: c.Live,
		CodexLoginMode: c.codexLoginMode(),
	})
	p.Schema = engine.SchemaPools
	b, err := json.Marshal(p)
	if err != nil {
		return nil, err
	}
	return engine.ParsePools(b)
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
