// Package config is AFK's settings: ~/.config/afk/config.toml (the schema
// below), the install record afk.lock beside it, and the few routing
// preferences a repository may set in its own .afk/config.json.
//
// Secrets never appear in config: a key is a reference (env:NAME,
// file:/path, cmd:..., op://..., keychain:NAME) that is resolved only at
// the moment it is used, and never written to disk or printed.
package config

import (
	"fmt"
	"net/url"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
)

// Version is the config.toml schema version this AFK reads and writes.
const Version = 1

// Config is config.toml.
type Config struct {
	Version     int                  `toml:"version"`
	Route       Route                `toml:"route"`
	Permissions Permissions          `toml:"permissions"`
	Trust       Trust                `toml:"trust"`
	Harness     map[string]Harness   `toml:"harness"`
	Gateway     map[string]Gateway   `toml:"gateway"`
	Bench       Bench                `toml:"bench"`
	Serve       Serve                `toml:"serve"`
	Telemetry   map[string]Telemetry `toml:"telemetry"`
	Source      map[string]Source    `toml:"source"`
}

// Route is how a task is routed.
type Route struct {
	// Prefer is balanced (default), cheap or best.
	Prefer string `toml:"prefer,omitempty"`
	// PreferFree sends low-risk work to free and local models first.
	PreferFree *bool `toml:"prefer_free,omitempty"`
	// AllowMetered lets pay-per-token API models be picked.
	AllowMetered *bool `toml:"allow_metered,omitempty"`
	// AllowFreeReviewers lets free models review.
	AllowFreeReviewers *bool `toml:"allow_free_reviewers,omitempty"`
	// SecurityModels are the restricted security models you are entitled
	// to (Mythos, Daybreak Blue).
	SecurityModels []string `toml:"security_models,omitempty"`
	// Failover is where a failed one-shot run may go next: any (default),
	// same-pool or none.
	Failover string `toml:"failover,omitempty"`
	// Learn lets your ratings of past runs move route scores (default on).
	Learn *bool `toml:"learn,omitempty"`
	// Pacing leans routing toward plan quota about to reset unused and
	// away from a plan that will run out first (default on).
	Pacing *bool `toml:"pacing,omitempty"`
}

// Permissions is the default permission mode. Reserved: the modes are
// validated but not applied yet.
type Permissions struct {
	Default string            `toml:"default,omitempty"`
	Task    map[string]string `toml:"task,omitempty"`
}

// Trust lists the directories you trust.
type Trust struct {
	// Repos are projects whose .afk/config.json may still name a gateway
	// through the old router block.
	Repos []string `toml:"repos,omitempty"`
}

// Harness is one agent CLI.
type Harness struct {
	// Enabled false keeps the CLI out of routing.
	Enabled *bool `toml:"enabled,omitempty"`
}

// Gateway is one model gateway.
type Gateway struct {
	Kind    string   `toml:"kind,omitempty"`
	URL     string   `toml:"url,omitempty"`
	Key     string   `toml:"key,omitempty"` // a secret reference, never a key
	Formats []string `toml:"formats,omitempty"`
	Cost    string   `toml:"cost,omitempty"`
	Default bool     `toml:"default,omitempty"`
}

// Bench is the benchmark catalog's sources.
type Bench struct {
	// Autosync false stops the daily background refresh.
	Autosync *bool                         `toml:"autosync,omitempty"`
	Sources  map[string]BenchSource        `toml:"sources,omitempty"`
	Weights  map[string]map[string]float64 `toml:"weights,omitempty"`  // reserved
	Override map[string]map[string]float64 `toml:"override,omitempty"` // reserved
}

// BenchSource turns one benchmark feed on or off.
type BenchSource struct {
	Enabled *bool `toml:"enabled,omitempty"`
}

// Serve is afk serve. Reserved.
type Serve struct {
	Listen   string `toml:"listen,omitempty"`
	TLS      *bool  `toml:"tls,omitempty"`
	PlanRuns *bool  `toml:"plan_runs,omitempty"`
}

// Telemetry is one telemetry sink. Reserved.
type Telemetry struct {
	Kind     string `toml:"kind,omitempty"`
	Endpoint string `toml:"endpoint,omitempty"`
	Key      string `toml:"key,omitempty"` // a secret reference
	Content  *bool  `toml:"content,omitempty"`
}

// Source is one work source. Reserved.
type Source struct {
	Kind        string   `toml:"kind,omitempty"`
	Repo        string   `toml:"repo,omitempty"`
	Labels      []string `toml:"labels,omitempty"`
	Task        string   `toml:"task,omitempty"`
	Mode        string   `toml:"mode,omitempty"`
	ApprovePlan *bool    `toml:"approve_plan,omitempty"`
}

// Allowed values.
var (
	Prefers   = []string{"balanced", "cheap", "best"}
	Failovers = []string{"any", "same-pool", "none"}
	Modes     = []string{"read-only", "ask", "edits", "auto", "yolo"}
	Gateways  = []string{"litellm", "openrouter", "portkey", "agentgateway", "envoy", "kong", "cloudflare", "vercel", "openai", "anthropic", "ollama", "lmstudio", "vllm", "llamacpp", "localai"}
	Costs     = []string{"metered", "free"}
	Formats   = []string{"openai-chat", "openai-responses", "anthropic-messages"}
	BenchSrcs = []string{"lmarena", "modelsdev", "swebench", "artificialanalysis", "own"}
)

// ModeRank orders the permission modes from strictest to loosest.
func ModeRank(m string) int {
	for i, x := range Modes {
		if x == m {
			return i
		}
	}
	return -1
}

// Problem is one validation error, or a warning.
type Problem struct {
	File string `json:"file"`
	Line int    `json:"line,omitempty"`
	Key  string `json:"key"`
	Msg  string `json:"message"`
}

func (p Problem) Error() string { return p.String() }

func (p Problem) String() string {
	loc := p.File
	if p.Line > 0 {
		loc = fmt.Sprintf("%s:%d", p.File, p.Line)
	}
	if p.Key == "" {
		return plain(fmt.Sprintf("%s: %s", loc, p.Msg))
	}
	return plain(fmt.Sprintf("%s: %s: %s", loc, p.Key, p.Msg))
}

// plain replaces control characters. A problem can quote a key or a value
// from a repository's file, and a terminal would act on an escape sequence
// in it (move the cursor, rewrite the line above, set the title).
func plain(s string) string {
	return strings.Map(func(r rune) rune {
		if r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) {
			return '?'
		}
		return r
	}, s)
}

// validate checks the values. lines maps a dotted key to its line.
func (c *Config) validate(file string, lines map[string]int) []Problem {
	var out []Problem
	bad := func(key, format string, a ...any) {
		out = append(out, Problem{File: file, Line: lineOf(lines, key), Key: key, Msg: fmt.Sprintf(format, a...)})
	}
	oneOf := func(key, v string, allowed []string) {
		if v != "" && !contains(allowed, v) {
			bad(key, "%q is not one of %s", v, strings.Join(allowed, ", "))
		}
	}
	if c.Version != Version {
		bad("version", "this afk reads version %d, not %d", Version, c.Version)
	}
	oneOf("route.prefer", c.Route.Prefer, Prefers)
	oneOf("route.failover", c.Route.Failover, Failovers)
	oneOf("permissions.default", c.Permissions.Default, Modes)
	for _, t := range sortedKeys(c.Permissions.Task) {
		oneOf("permissions.task."+t, c.Permissions.Task[t], Modes)
	}
	defaults := 0
	for _, n := range sortedKeys(c.Gateway) {
		g := c.Gateway[n]
		p := "gateway." + n
		oneOf(p+".kind", g.Kind, Gateways)
		oneOf(p+".cost", g.Cost, Costs)
		for _, f := range g.Formats {
			oneOf(p+".formats", f, Formats)
		}
		if g.URL == "" {
			bad(p+".url", "a gateway needs a url")
		} else if u, err := url.Parse(g.URL); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			bad(p+".url", "not an http(s) URL")
		} else if u.User != nil {
			// Never echo it: user info in a URL is a credential.
			bad(p+".url", "the URL carries user info (a credential); put the key in key = \"env:NAME\" instead")
		}
		if g.Key != "" {
			if _, err := ParseSecretRef(g.Key); err != nil {
				bad(p+".key", "%s", err)
			}
		}
		if g.Default {
			defaults++
		}
	}
	if defaults > 1 {
		bad("gateway", "more than one gateway has default = true")
	}
	for _, n := range sortedKeys(c.Telemetry) {
		t := c.Telemetry[n]
		if t.Key != "" {
			if _, err := ParseSecretRef(t.Key); err != nil {
				bad("telemetry."+n+".key", "%s", err)
			}
		}
	}
	for _, n := range sortedKeys(c.Source) {
		oneOf("source."+n+".mode", c.Source[n].Mode, Modes)
	}
	for _, n := range sortedKeys(c.Bench.Sources) {
		if !contains(BenchSrcs, n) {
			bad("bench.sources."+n, "unknown source; known: %s", strings.Join(BenchSrcs, ", "))
		}
	}
	for _, kind := range sortedKeys(c.Bench.Weights) {
		for _, src := range sortedKeys(c.Bench.Weights[kind]) {
			if w := c.Bench.Weights[kind][src]; w < 0 {
				bad("bench.weights."+kind+"."+src, "a weight can't be negative")
			}
		}
	}
	// A relative trust entry would resolve against wherever afk runs.
	for _, t := range c.Trust.Repos {
		if t != "~" && !strings.HasPrefix(t, "~/") && !filepath.IsAbs(t) {
			bad("trust.repos", "%q is not an absolute path or a path under ~", t)
		}
	}
	return out
}

// lineOf finds the line of a key, or of the nearest table above it.
func lineOf(lines map[string]int, key string) int {
	for k := key; k != ""; {
		if l, ok := lines[k]; ok {
			return l
		}
		i := strings.LastIndex(k, ".")
		if i < 0 {
			break
		}
		k = k[:i]
	}
	return 0
}

// KeyType is the kind of value a key holds: string, bool, int, float,
// strings (a list), table (a section), or "" for a key that isn't in the
// schema.
func KeyType(key string) string {
	t := reflect.TypeOf(Config{})
	parts := strings.Split(key, ".")
	for i := 0; i < len(parts); i++ {
		switch t.Kind() {
		case reflect.Struct:
			f, ok := fieldByTag(t, parts[i])
			if !ok {
				return ""
			}
			t = f.Type
		case reflect.Map:
			// A map key is a name the user chose.
			t = t.Elem()
		default:
			return ""
		}
		if t.Kind() == reflect.Pointer {
			t = t.Elem()
		}
	}
	switch t.Kind() {
	case reflect.String:
		return "string"
	case reflect.Bool:
		return "bool"
	case reflect.Int:
		return "int"
	case reflect.Float64:
		return "float"
	case reflect.Slice:
		if t.Elem().Kind() == reflect.String {
			return "strings"
		}
	case reflect.Struct, reflect.Map:
		return "table"
	}
	return ""
}

func fieldByTag(t reflect.Type, name string) (reflect.StructField, bool) {
	for i := 0; i < t.NumField(); i++ {
		f := t.Field(i)
		if tag, _, _ := strings.Cut(f.Tag.Get("toml"), ","); tag == name {
			return f, true
		}
	}
	return reflect.StructField{}, false
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

func sortedKeys[V any](m map[string]V) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}
