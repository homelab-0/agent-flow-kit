package config

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Repo is what a repository's .afk/config.json may set. A cloned
// repository is someone else's file, so it may only make routing choices
// for itself: never a gateway, a key, an install, telemetry, a work
// source, or a looser permission mode. Any other key is ignored with a
// warning that names it.
type Repo struct {
	Path   string
	Exists bool
	// Route preferences.
	Prefer     string
	PreferFree *bool
	// Permission mode: may only be stricter than yours (reserved).
	Mode string
	// The old "router" block, read as before for compatibility.
	Legacy   LegacyRepo
	Warnings []Problem
}

// LegacyRepo is the router block older AFK versions read from a project.
type LegacyRepo struct {
	GatewayURL         *string  `json:"litellm_base_url"`
	AllowMetered       *bool    `json:"allow_metered_api"`
	PreferFree         *bool    `json:"prefer_free_for_low_risk"`
	AllowFreeReviewers *bool    `json:"allow_free_reviewers"`
	SecurityModels     []string `json:"security_models"`
}

// repoAllowed are the keys a repository may set, by section.
var repoAllowed = map[string][]string{
	"route":       {"prefer", "prefer_free"},
	"permissions": {"default"},
}

// LoadRepo reads <repo>/.afk/config.json.
func LoadRepo(repo string) *Repo {
	r := &Repo{}
	if repo == "" {
		return r
	}
	r.Path = filepath.Join(repo, ".afk", "config.json")
	b, err := os.ReadFile(r.Path)
	if errors.Is(err, fs.ErrNotExist) || err != nil {
		return r
	}
	r.Exists = true
	var top map[string]json.RawMessage
	if json.Unmarshal(b, &top) != nil {
		r.Warnings = append(r.Warnings, Problem{File: r.Path, Msg: "not valid JSON; ignored"})
		return r
	}
	warn := func(key, msg string) {
		r.Warnings = append(r.Warnings, Problem{File: r.Path, Key: key, Msg: msg})
	}
	for _, k := range sortedKeys(top) {
		switch k {
		case "router":
			_ = json.Unmarshal(top[k], &r.Legacy)
		case "route", "permissions":
			var sec map[string]json.RawMessage
			if json.Unmarshal(top[k], &sec) != nil {
				warn(k, "not an object; ignored")
				continue
			}
			for _, sk := range sortedKeys(sec) {
				if !contains(repoAllowed[k], sk) {
					warn(k+"."+sk, "a repository can't set this; ignored")
					continue
				}
				r.set(k+"."+sk, sec[sk], warn)
			}
		default:
			warn(k, "a repository can set only route preferences (route.prefer, route.prefer_free) and a stricter permissions.default; ignored")
		}
	}
	return r
}

func (r *Repo) set(key string, raw json.RawMessage, warn func(key, msg string)) {
	switch key {
	case "route.prefer":
		var s string
		if json.Unmarshal(raw, &s) != nil || !contains(Prefers, s) {
			warn(key, "must be one of "+strings.Join(Prefers, ", ")+"; ignored")
			return
		}
		r.Prefer = s
	case "route.prefer_free":
		var b bool
		if json.Unmarshal(raw, &b) != nil {
			warn(key, "must be true or false; ignored")
			return
		}
		r.PreferFree = &b
	case "permissions.default":
		var s string
		if json.Unmarshal(raw, &s) != nil || ModeRank(s) < 0 {
			warn(key, "must be one of "+strings.Join(Modes, ", ")+"; ignored")
			return
		}
		r.Mode = s
	}
}

// legacyUser is ~/.config/afk/router.json, the settings file before
// config.toml.
type legacyUser struct {
	GatewayURL   string   `json:"litellm_base_url"`
	Security     []string `json:"security_models"`
	TrustedRepos []string `json:"trusted_repos"`
}

func readLegacyUser(path string) (legacyUser, bool) {
	var u legacyUser
	b, err := os.ReadFile(path)
	if err != nil {
		return u, false
	}
	return u, json.Unmarshal(b, &u) == nil
}

// Settings are the effective routing settings for one run.
type Settings struct {
	Prefer             string
	GatewayURL         string
	GatewayName        string
	GatewayKey         *SecretRef // the default gateway's key reference, if config names one
	AllowMetered       bool
	PreferFree         bool
	AllowFreeReviewers bool
	SecurityModels     []string
	// IgnoredRepoGateway: the project named a gateway that was not used
	// because the project isn't trusted.
	IgnoredRepoGateway bool
	// Disabled are CLIs config keeps out of routing.
	Disabled map[string]bool
	// BenchAutosync is whether the daily catalog refresh runs.
	BenchAutosync bool
	// BenchSources says which feeds a sync reads (a missing name is on).
	BenchSources map[string]bool
	// Mode is the default permission mode (reserved: not applied yet).
	Mode string
	// Warnings from config.toml and the project's file.
	Warnings []Problem
	// FromTOML says whether config.toml was found (else router.json, if
	// any, was used).
	FromTOML bool
}

// Env is what Resolve reads.
type Env struct {
	Home   string
	Getenv func(string) string
	// Repo is the project directory whose .afk/config.json applies.
	Repo string
}

func (e Env) getenv(k string) string {
	if e.Getenv == nil {
		return ""
	}
	return e.Getenv(k)
}

func truthy(v string) bool { return v == "true" || v == "1" }

// Resolve works out the settings. Each is taken from the first of: the
// environment, the project's .afk/config.json (the keys it may set),
// config.toml, defaults. While config.toml is absent, ~/.config/afk/
// router.json is read in its place, so an existing setup works unchanged.
// Command-line flags are applied on top by the caller.
func Resolve(e Env) (Settings, error) {
	paths := PathsFor(e.Home, e.Getenv)
	f, err := Load(paths.Config)
	if err != nil {
		return Settings{}, err
	}
	s := Settings{Prefer: "balanced", BenchAutosync: true, FromTOML: f.Exists, Disabled: map[string]bool{}, BenchSources: map[string]bool{}}
	s.Warnings = append(s.Warnings, f.Warnings...)
	c := f.Config

	// The user's own settings: config.toml, else router.json.
	userGateway, userSecurity, trusted := "", []string(nil), []string(nil)
	if f.Exists {
		if name, g, ok := c.DefaultGateway(); ok {
			userGateway, s.GatewayName = g.URL, name
			if g.Key != "" {
				if r, err := ParseSecretRef(g.Key); err == nil {
					s.GatewayKey = &r
				}
			}
		}
		userSecurity, trusted = c.Route.SecurityModels, c.Trust.Repos
	} else if u, ok := readLegacyUser(paths.Legacy); ok {
		userGateway, userSecurity, trusted = u.GatewayURL, u.Security, u.TrustedRepos
	}

	repo := LoadRepo(e.Repo)
	s.Warnings = append(s.Warnings, repo.Warnings...)
	lr := repo.Legacy

	// The gateway gets the gateway key at launch, so its address must come
	// from you: the environment, your own config, or (the old router
	// block) a project you trust. A cloned repository can't point your key
	// at its own server.
	s.GatewayURL = e.getenv("AFK_LITELLM_BASE_URL")
	if s.GatewayURL != "" {
		s.GatewayName = "default"
	}
	if s.GatewayURL == "" {
		s.GatewayURL = userGateway
	}
	if s.GatewayURL == "" && lr.GatewayURL != nil && *lr.GatewayURL != "" {
		if trusts(trusted, e.Repo) {
			s.GatewayURL = *lr.GatewayURL
		} else {
			s.IgnoredRepoGateway = true
		}
	}

	pick := func(env string, repoV, legacyV, cfgV *bool) bool {
		if v := e.getenv(env); v != "" {
			return truthy(v)
		}
		for _, p := range []*bool{repoV, legacyV, cfgV} {
			if p != nil {
				return *p
			}
		}
		return false
	}
	s.AllowMetered = pick("AFK_ROUTER_ALLOW_METERED_API", nil, lr.AllowMetered, c.Route.AllowMetered)
	s.PreferFree = pick("AFK_ROUTER_PREFER_FREE", repo.PreferFree, lr.PreferFree, c.Route.PreferFree)
	s.AllowFreeReviewers = pick("AFK_ROUTER_ALLOW_FREE_REVIEWERS", nil, lr.AllowFreeReviewers, c.Route.AllowFreeReviewers)
	switch {
	case e.getenv("AFK_SECURITY_MODELS") != "":
		s.SecurityModels = strings.Split(e.getenv("AFK_SECURITY_MODELS"), ",")
	case len(lr.SecurityModels) > 0:
		s.SecurityModels = lr.SecurityModels
	default:
		s.SecurityModels = userSecurity
	}

	switch {
	case repo.Prefer != "":
		s.Prefer = repo.Prefer
	case c.Route.Prefer != "":
		s.Prefer = c.Route.Prefer
	}

	s.Mode = c.Permissions.Default
	if s.Mode == "" {
		s.Mode = "ask"
	}
	if repo.Mode != "" && ModeRank(repo.Mode) < ModeRank(s.Mode) {
		// Stricter only: a repository can't loosen your mode.
		s.Mode = repo.Mode
	} else if repo.Mode != "" && ModeRank(repo.Mode) > ModeRank(s.Mode) {
		s.Warnings = append(s.Warnings, Problem{File: repo.Path, Key: "permissions.default", Msg: "a repository can only make the mode stricter than yours (" + s.Mode + "); ignored"})
	}

	for _, n := range sortedKeys(c.Harness) {
		if h := c.Harness[n]; h.Enabled != nil && !*h.Enabled {
			s.Disabled[n] = true
		}
	}
	if c.Bench.Autosync != nil {
		s.BenchAutosync = *c.Bench.Autosync
	}
	if e.getenv("AFK_SKIP_BENCHMARK_AUTOSYNC") == "1" {
		s.BenchAutosync = false
	}
	for _, n := range sortedKeys(c.Bench.Sources) {
		if src := c.Bench.Sources[n]; src.Enabled != nil {
			s.BenchSources[n] = *src.Enabled
		}
	}
	return s, nil
}

// BenchSourceOn reports whether a feed is enabled (on unless config turns
// it off).
func (s Settings) BenchSourceOn(name string) bool {
	on, set := s.BenchSources[name]
	return !set || on
}

// DefaultGateway is the gateway marked default = true, or the only one.
func (c Config) DefaultGateway() (string, Gateway, bool) {
	names := sortedKeys(c.Gateway)
	for _, n := range names {
		if c.Gateway[n].Default {
			return n, c.Gateway[n], true
		}
	}
	if len(names) == 1 {
		return names[0], c.Gateway[names[0]], true
	}
	return "", Gateway{}, false
}

// trusts reports whether a project directory is listed (compared after
// resolving symlinks).
func trusts(list []string, repo string) bool {
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
	for _, t := range list {
		if t != "" && real(t) == want {
			return true
		}
	}
	return false
}
