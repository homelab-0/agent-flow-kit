package config

import (
	"encoding/json"
	"errors"
	"io/fs"
	"net"
	"net/url"
	"os"
	"path/filepath"
	"sort"
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

// LegacyRepo is what is still read from the router block older AFK
// versions read from a project: its route preference only.
type LegacyRepo struct {
	PreferFree *bool
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
			// The older block: only its route preference is still read. A
			// gateway, keys, metered models, free reviewers or security
			// models from someone else's repository are ignored, trusted
			// or not.
			var sec map[string]json.RawMessage
			if json.Unmarshal(top[k], &sec) != nil {
				warn(k, "not an object; ignored")
				continue
			}
			for _, sk := range sortedKeys(sec) {
				if sk != "prefer_free_for_low_risk" {
					warn("router."+sk, "a repository can't set this (only route.prefer, route.prefer_free and a stricter permissions.default); ignored")
					continue
				}
				var b bool
				if json.Unmarshal(sec[sk], &b) != nil {
					warn("router."+sk, "must be true or false; ignored")
					continue
				}
				r.Legacy.PreferFree = &b
			}
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
	Prefer      string
	GatewayURL  string
	GatewayName string
	GatewayKey  *SecretRef // the default gateway's key reference, if config names one
	// Gateways are config.toml's gateways, by name, for matching a route's
	// gateway URL to its own key.
	Gateways           map[string]Gateway
	AllowMetered       bool
	PreferFree         bool
	AllowFreeReviewers bool
	SecurityModels     []string
	// Disabled are CLIs config keeps out of routing.
	Disabled map[string]bool
	// BenchAutosync is whether the daily catalog refresh runs.
	BenchAutosync bool
	// BenchSources says which feeds a sync reads (a missing name is on).
	BenchSources map[string]bool
	// Mode is the default permission mode: permissions.default, else ask,
	// made stricter by the project's permissions.default.
	Mode string
	// TaskModes are permissions.task.<kind>; RepoMode is the project's
	// permissions.default (it can only tighten).
	TaskModes map[string]string
	RepoMode  string
	// TrustedDirs are trust.repos: where yolo is allowed.
	TrustedDirs []string
	// DefaultMode is permissions.default as written ("" when unset).
	DefaultMode string
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
	userGateway, userSecurity := "", []string(nil)
	if f.Exists {
		if name, g, ok := c.DefaultGateway(); ok {
			userGateway, s.GatewayName = g.URL, name
			if g.Key != "" {
				if r, err := ParseSecretRef(g.Key); err == nil {
					s.GatewayKey = &r
				}
			}
		}
		userSecurity = c.Route.SecurityModels
		s.Gateways = c.Gateway
	} else if u, ok := readLegacyUser(paths.Legacy); ok {
		userGateway, userSecurity = u.GatewayURL, u.Security
	}

	repo := LoadRepo(e.Repo)
	s.Warnings = append(s.Warnings, repo.Warnings...)
	lr := repo.Legacy

	// The gateway gets the gateway key at launch, so its address comes
	// only from you: the environment or your own config. A repository can
	// never point your key at its own server.
	s.GatewayURL = e.getenv("AFK_LITELLM_BASE_URL")
	if s.GatewayURL != "" {
		s.GatewayName = "default"
	}
	if s.GatewayURL == "" {
		s.GatewayURL = userGateway
	}

	// A key sent over plain http to another network can be read on the
	// way. Said once per address; the launch still goes ahead.
	plainSeen := map[string]bool{}
	warnPlain := func(key, raw string) {
		if !PlainHTTP(raw) || plainSeen[raw] {
			return
		}
		plainSeen[raw] = true
		s.Warnings = append(s.Warnings, Problem{File: paths.Config, Key: key, Msg: "the gateway address " + hostOf(raw) + " is plain http on what looks like a public host, so its key travels unencrypted; use https"})
	}
	warnPlain("gateway", s.GatewayURL)
	// A route can pick any named gateway, not only the default.
	names := make([]string, 0, len(s.Gateways))
	for n := range s.Gateways {
		names = append(names, n)
	}
	sort.Strings(names)
	for _, n := range names {
		warnPlain("gateway."+n+".url", s.Gateways[n].URL)
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
	s.AllowMetered = pick("AFK_ROUTER_ALLOW_METERED_API", nil, nil, c.Route.AllowMetered)
	s.PreferFree = pick("AFK_ROUTER_PREFER_FREE", repo.PreferFree, lr.PreferFree, c.Route.PreferFree)
	s.AllowFreeReviewers = pick("AFK_ROUTER_ALLOW_FREE_REVIEWERS", nil, nil, c.Route.AllowFreeReviewers)
	switch {
	case e.getenv("AFK_SECURITY_MODELS") != "":
		s.SecurityModels = strings.Split(e.getenv("AFK_SECURITY_MODELS"), ",")
	default:
		s.SecurityModels = userSecurity
	}

	switch {
	case repo.Prefer != "":
		s.Prefer = repo.Prefer
	case c.Route.Prefer != "":
		s.Prefer = c.Route.Prefer
	}

	s.TaskModes, s.RepoMode, s.DefaultMode = c.Permissions.Task, repo.Mode, c.Permissions.Default
	s.TrustedDirs = c.Trust.Repos
	s.Mode = s.ModeFor("")
	if repo.Mode != "" && ModeRank(repo.Mode) > ModeRank(s.Mode) {
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

// ModeFor is the permission mode for a kind of task, before a --mode or
// --yolo flag: permissions.task.<kind>, else permissions.default, else ask;
// then the project's permissions.default when it is stricter (a project
// can tighten your mode, never loosen it).
func (s Settings) ModeFor(task string) string {
	m := s.TaskModes[task]
	if m == "" {
		m = s.DefaultMode
	}
	if m == "" {
		m = "ask"
	}
	if s.RepoMode != "" && ModeRank(s.RepoMode) >= 0 && ModeRank(s.RepoMode) < ModeRank(m) {
		m = s.RepoMode
	}
	return m
}

// BenchSourceOn reports whether a feed is enabled (on unless config turns
// it off).
func (s Settings) BenchSourceOn(name string) bool {
	on, set := s.BenchSources[name]
	return !set || on
}

// GatewayFor finds the config.toml gateway whose url is u (ignoring a
// trailing slash).
func (s Settings) GatewayFor(u string) (string, Gateway, bool) {
	norm := func(x string) string { return strings.TrimRight(x, "/") }
	for _, n := range sortedKeys(s.Gateways) {
		if g := s.Gateways[n]; norm(g.URL) == norm(u) {
			return n, g, true
		}
	}
	return "", Gateway{}, false
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

// PlainHTTP reports a gateway address that is http:// to a host that
// doesn't look local: not loopback, a private or tailnet address, a bare
// name, or a name under a local-only suffix.
func PlainHTTP(raw string) bool {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "http" {
		return false
	}
	h := strings.ToLower(u.Hostname())
	if ip := net.ParseIP(h); ip != nil {
		cgnat := net.IPNet{IP: net.IPv4(100, 64, 0, 0), Mask: net.CIDRMask(10, 32)}
		return !(ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || cgnat.Contains(ip))
	}
	if h == "" || !strings.Contains(h, ".") {
		return false
	}
	for _, suf := range []string{".localhost", ".local", ".lan", ".home", ".internal", ".home.arpa", ".ts.net", ".svc", ".cluster.local", ".test"} {
		if strings.HasSuffix(h, suf) {
			return false
		}
	}
	return true
}

// hostOf is an address's host, for messages (never its user info or query).
func hostOf(raw string) string {
	if u, err := url.Parse(raw); err == nil {
		return u.Host
	}
	return "(unreadable)"
}
