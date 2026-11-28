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
	"net"
	"net/url"
	"path/filepath"
	"reflect"
	"regexp"
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
	Discovery   Discovery            `toml:"discovery"`
	Gateway     map[string]Gateway   `toml:"gateway"`
	Local       Local                `toml:"local"`
	Bench       Bench                `toml:"bench"`
	Serve       Serve                `toml:"serve"`
	Telemetry   map[string]Telemetry `toml:"telemetry"`
	Source      map[string]Source    `toml:"source"`
}

// Discovery is how AFK learns what each installed CLI has.
type Discovery struct {
	// Auto false stops AFK asking the CLIs again by itself: the last
	// answers are used until afk harness scan (or a new CLI version).
	Auto *bool `toml:"auto,omitempty"`
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
	// VendorUsage true lets AFK read the login this CLI saved and ask
	// its vendor for plan usage, when the CLI itself reports none.
	// Default off: a vendor's terms may not allow another tool to use
	// its CLI's login. Only config.toml can turn it on, never a
	// repository.
	VendorUsage *bool `toml:"vendor_usage,omitempty"`
}

// Gateway is one model gateway.
type Gateway struct {
	Kind    string   `toml:"kind,omitempty"`
	URL     string   `toml:"url,omitempty"`
	Key     string   `toml:"key,omitempty"` // a secret reference, never a key
	Formats []string `toml:"formats,omitempty"`
	Cost    string   `toml:"cost,omitempty"`
	Default bool     `toml:"default,omitempty"`
	// Engine and Host say what serves the gateway's models and where
	// (for example "vllm" on "factory"). They are labels for the route
	// card only.
	Engine string `toml:"engine,omitempty"`
	Host   string `toml:"host,omitempty"`
	// MCP is the gateway's MCP endpoint, for servers in mcp.toml with
	// via = this gateway (default: /mcp on the gateway's host).
	MCP string `toml:"mcp,omitempty"`
}

// Local is the inference engines on this machine (Ollama, LM Studio,
// llama.cpp, vLLM, SGLang, ...).
type Local struct {
	// Engines is "auto" (default: look on the usual ports) or "off" (only
	// at URLs).
	Engines string `toml:"engines,omitempty"`
	// URLs are more addresses on this machine to look at, for an engine
	// on a port of its own. Only loopback addresses are allowed.
	URLs []string `toml:"urls,omitempty"`
	// GPU names this machine's GPU for the route card, in place of what
	// nvidia-smi reports.
	GPU string `toml:"gpu,omitempty"`
}

// Bench is the benchmark catalog's sources.
type Bench struct {
	// Autosync false stops the daily background refresh.
	Autosync *bool                  `toml:"autosync,omitempty"`
	Sources  map[string]BenchSource `toml:"sources,omitempty"`
	// Weights is each source's weight per task kind:
	// [bench.weights.coding_complex] swebench = 2.
	Weights  map[string]map[string]float64 `toml:"weights,omitempty"`
	Override map[string]map[string]float64 `toml:"override,omitempty"` // reserved
	// Custom are leaderboards of the user's own: [bench.custom.<id>].
	Custom map[string]BenchCustom `toml:"custom,omitempty"`
}

// BenchCustom is a leaderboard the user added. AFK fetches url (or reads
// file), takes the rows at rows, and reads each row's model and score
// fields; an empty field is detected. tasks are the task kinds its score
// counts for. key, when set, is a reference to an API key (env:NAME only)
// sent in key_header.
type BenchCustom struct {
	Name      string   `toml:"name,omitempty"`
	URL       string   `toml:"url,omitempty"`
	File      string   `toml:"file,omitempty"`
	Format    string   `toml:"format,omitempty"`
	Rows      string   `toml:"rows,omitempty"`
	Model     string   `toml:"model,omitempty"`
	Score     string   `toml:"score,omitempty"`
	Lower     *bool    `toml:"lower,omitempty"`
	Tasks     []string `toml:"tasks,omitempty"`
	Weight    *float64 `toml:"weight,omitempty"`
	Key       string   `toml:"key,omitempty"`
	KeyHeader string   `toml:"key_header,omitempty"`
	Measures  string   `toml:"measures,omitempty"`
	Enabled   *bool    `toml:"enabled,omitempty"`
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
	Prefers    = []string{"balanced", "cheap", "best"}
	Failovers  = []string{"any", "same-pool", "none"}
	Modes      = []string{"read-only", "ask", "edits", "auto", "yolo"}
	Gateways   = []string{"litellm", "openrouter", "portkey", "agentgateway", "envoy", "kong", "cloudflare", "vercel", "openai", "anthropic", "ollama", "lmstudio", "vllm", "llamacpp", "localai"}
	Costs      = []string{"metered", "free"}
	LocalModes = []string{"auto", "off"}
	Engines    = []string{"vllm", "ollama", "llamacpp", "lmstudio", "sglang", "tgi", "localai", "mlx"}
	Formats    = []string{"openai-chat", "openai-responses", "anthropic-messages"}
	BenchSrcs  = []string{"lmarena", "modelsdev", "swebench", "aider", "artificialanalysis", "own"}
	// BenchTasks are the task kinds a benchmark source can score.
	BenchTasks   = []string{"coding_complex", "coding_standard", "coding_review", "architecture", "security", "webdev", "research", "frontier_synthesis"}
	BenchFormats = []string{"json", "yaml", "csv"}
	benchIDRE    = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
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
	oneOf("local.engines", c.Local.Engines, LocalModes)
	for _, u := range c.Local.URLs {
		if !loopback(u) {
			// Not quoted: it may carry user info.
			bad("local.urls", "each must be an http address on this machine (localhost, 127.0.0.1 or ::1), without user info; an engine on another machine is a [gateway]")
			break
		}
	}
	if len(c.Local.GPU) > 40 || plain(c.Local.GPU) != c.Local.GPU {
		bad("local.gpu", "a short label, without control characters")
	}
	defaults := 0
	for _, n := range sortedKeys(c.Gateway) {
		g := c.Gateway[n]
		p := "gateway." + n
		oneOf(p+".kind", g.Kind, Gateways)
		oneOf(p+".cost", g.Cost, Costs)
		oneOf(p+".engine", g.Engine, Engines)
		if len(n) > 40 || plain(n) != n {
			bad("gateway", "a gateway name is a short label, without control characters")
		}
		if len(g.Host) > 40 || plain(g.Host) != g.Host {
			bad(p+".host", "a short label, without control characters")
		}
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
		if g.MCP != "" {
			if u, err := url.Parse(g.MCP); err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
				bad(p+".mcp", "not an http(s) URL")
			} else if u.User != nil {
				bad(p+".mcp", "the URL carries user info (a credential); use bearer = \"env:NAME\" in mcp.toml instead")
			}
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
	for _, id := range sortedKeys(c.Bench.Custom) {
		b, k := c.Bench.Custom[id], "bench.custom."+id
		switch {
		case !benchIDRE.MatchString(id):
			bad(k, "a source id is lower-case letters, digits and dashes")
		case contains(BenchSrcs, id):
			bad(k, "%s is a built-in source's id; pick another", id)
		}
		switch {
		case b.URL == "" && b.File == "":
			bad(k, "needs a url or a file")
		case b.URL != "" && b.File != "":
			bad(k, "takes a url or a file, not both")
		case b.URL != "" && !strings.HasPrefix(b.URL, "https://") && !strings.HasPrefix(b.URL, "http://localhost") && !strings.HasPrefix(b.URL, "http://127.0.0.1"):
			bad(k+".url", "must be https:// (or http:// on this machine)")
		case b.File != "" && !strings.HasPrefix(b.File, "/") && !strings.HasPrefix(b.File, "~/"):
			bad(k+".file", "must be an absolute path or a path under ~")
		}
		if b.Format != "" {
			oneOf(k+".format", b.Format, BenchFormats)
		}
		for _, t := range b.Tasks {
			if !contains(BenchTasks, t) {
				bad(k+".tasks", "unknown task kind %q; known: %s", t, strings.Join(BenchTasks, ", "))
			}
		}
		if b.Weight != nil && *b.Weight < 0 {
			bad(k+".weight", "a weight can't be negative")
		}
		if b.Key != "" {
			if r, err := ParseSecretRef(b.Key); err != nil {
				bad(k+".key", "%s", err)
			} else if r.Kind != "env" {
				bad(k+".key", "a source's key must be env:NAME")
			} else if b.KeyHeader == "" {
				bad(k+".key_header", "a key needs the header to send it in")
			}
		}
	}
	for _, kind := range sortedKeys(c.Bench.Weights) {
		if !contains(BenchTasks, kind) {
			bad("bench.weights."+kind, "unknown task kind; known: %s", strings.Join(BenchTasks, ", "))
		}
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

// loopback reports whether u is an http(s) URL on this machine.
func loopback(u string) bool {
	p, err := url.Parse(u)
	if err != nil || (p.Scheme != "http" && p.Scheme != "https") || p.User != nil || p.Host == "" {
		return false
	}
	h := p.Hostname()
	if h == "localhost" {
		return true
	}
	ip := net.ParseIP(h)
	return ip != nil && ip.IsLoopback()
}
