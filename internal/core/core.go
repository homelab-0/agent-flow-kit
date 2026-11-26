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
	// Headless runs a print-mode CLI (tests; nil runs it for real).
	Headless Headless
}

// New is the engine for this machine.
func New() *Core {
	he := harness.HostEnv()
	cwd, _ := os.Getwd()
	return &Core{Home: he.Home, Getenv: os.Getenv, Harness: he, Cwd: cwd, Live: true, Now: time.Now, Environ: os.Environ}
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

// Settings are the router settings: environment first, then the project's
// .afk/config.json "router" block, then ~/.config/afk/router.json for the
// security models.
type Settings struct {
	GatewayURL         string
	AllowMetered       bool
	PreferFree         bool
	AllowFreeReviewers bool
	SecurityModels     []string
	// IgnoredRepoGateway is set when the project names a gateway that was
	// not used because the project isn't trusted.
	IgnoredRepoGateway bool
}

// userRouter is ~/.config/afk/router.json: settings that are yours, not a
// project's.
type userRouter struct {
	GatewayURL   string   `json:"litellm_base_url"`
	Security     []string `json:"security_models"`
	TrustedRepos []string `json:"trusted_repos"`
}

func (c *Core) userRouterConfig() userRouter {
	var u userRouter
	if b, err := os.ReadFile(filepath.Join(c.Home, ".config", "afk", "router.json")); err == nil {
		_ = json.Unmarshal(b, &u)
	}
	return u
}

// trusts reports whether a project directory is listed in trusted_repos
// (compared after resolving symlinks).
func (u userRouter) trusts(repo string) bool {
	if repo == "" {
		return false
	}
	real := func(p string) string {
		if abs, err := filepath.Abs(p); err == nil {
			p = abs
		}
		if r, err := filepath.EvalSymlinks(p); err == nil {
			return r
		}
		return filepath.Clean(p)
	}
	want := real(repo)
	for _, t := range u.TrustedRepos {
		if t != "" && real(t) == want {
			return true
		}
	}
	return false
}

type projectConfig struct {
	Router struct {
		GatewayURL         *string  `json:"litellm_base_url"`
		AllowMetered       *bool    `json:"allow_metered_api"`
		PreferFree         *bool    `json:"prefer_free_for_low_risk"`
		AllowFreeReviewers *bool    `json:"allow_free_reviewers"`
		SecurityModels     []string `json:"security_models"`
	} `json:"router"`
}

func truthy(v string) bool { return v == "true" || v == "1" }

// LoadSettings reads the router settings for a project directory.
func (c *Core) LoadSettings(repo string) Settings {
	var pc projectConfig
	if repo != "" {
		if b, err := os.ReadFile(filepath.Join(repo, ".afk", "config.json")); err == nil {
			_ = json.Unmarshal(b, &pc)
		}
	}
	r := pc.Router
	s := Settings{}
	pick := func(env string, cfg *bool) bool {
		if v := c.getenv(env); v != "" {
			return truthy(v)
		}
		return cfg != nil && *cfg
	}
	user := c.userRouterConfig()
	// The gateway gets the gateway key at launch, so its address must come
	// from you: the environment, your own router.json, or a project you
	// have listed as trusted there. A cloned repository can't point your
	// key at its own server.
	s.GatewayURL = c.getenv("AFK_LITELLM_BASE_URL")
	if s.GatewayURL == "" {
		s.GatewayURL = user.GatewayURL
	}
	if s.GatewayURL == "" && r.GatewayURL != nil && *r.GatewayURL != "" {
		if user.trusts(repo) {
			s.GatewayURL = *r.GatewayURL
		} else {
			s.IgnoredRepoGateway = true
		}
	}
	s.AllowMetered = pick("AFK_ROUTER_ALLOW_METERED_API", r.AllowMetered)
	s.PreferFree = pick("AFK_ROUTER_PREFER_FREE", r.PreferFree)
	s.AllowFreeReviewers = pick("AFK_ROUTER_ALLOW_FREE_REVIEWERS", r.AllowFreeReviewers)
	if v := c.getenv("AFK_SECURITY_MODELS"); v != "" {
		s.SecurityModels = strings.Split(v, ",")
	} else if len(r.SecurityModels) > 0 {
		s.SecurityModels = r.SecurityModels
	} else {
		s.SecurityModels = user.Security
	}
	return s
}

// InstalledRoutable lists the routable CLIs found on this machine.
func (c *Core) InstalledRoutable() []string {
	var out []string
	for _, h := range Routable {
		a, ok := harness.Lookup(h)
		if ok && harness.Locate(c.Harness, a) != "" {
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
	s := c.LoadSettings(repo)
	installed := c.Installed
	if installed == nil {
		installed = router.VerifyBinaries(ctx, c.Harness, c.getenv)
	}
	probe := router.ProbePools(ctx, cat, router.ProbeEnv{
		Home: c.Home, Getenv: c.getenv, Now: c.now(), GatewayURL: s.GatewayURL,
		Installed: installed, Live: c.Live,
	})
	return &state{r: &router.Router{Catalog: cat, Probe: probe, Discovered: c.discovered()}, settings: s}, nil
}

// discovered reads the models the CLIs reported (written by the model
// sync), if any.
func (c *Core) discovered() []router.DiscoveredModel {
	p := c.getenv("AFK_DISCOVERED_MODELS_FILE")
	if p == "" {
		p = filepath.Join(c.Home, ".config", "afk", "discovered-models.json")
	}
	var d struct {
		Models []router.DiscoveredModel `json:"models"`
	}
	if b, err := os.ReadFile(p); err == nil {
		_ = json.Unmarshal(b, &d)
	}
	return d.Models
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
	// choice is the route: a router.Route, or the pinned route's map.
	choice any
}

// decide routes a prompt: checks the flags, finds the installed CLIs and
// asks the router.
func (c *Core) decide(ctx context.Context, f engine.RouteFlags, prompt string) (*decision, error) {
	prefer := f.Prefer
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
	repo := f.Repo
	if repo == "" {
		repo = c.Cwd
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
	d := &decision{
		st: st, repo: repo, task: task, prefer: prefer, guessed: guessed, installed: installed,
		pinH: pinH, pinM: pinM, list: installed, effort: f.Effort,
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
		return nil, &NoRouteError{"the router found no usable model for this task on " + strings.Join(d.list, ",")}
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
	s := c.LoadSettings(c.Cwd)
	installed := c.Installed
	if installed == nil {
		installed = router.VerifyBinaries(ctx, c.Harness, c.getenv)
	}
	p := router.ProbePools(ctx, cat, router.ProbeEnv{
		Home: c.Home, Getenv: c.getenv, Now: c.now(), GatewayURL: s.GatewayURL, Installed: installed, Live: c.Live,
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
