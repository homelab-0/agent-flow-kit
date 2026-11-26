// Package harness knows the agent CLIs AFK can drive: where each one is
// installed, what version it is, how it was installed and how to update it,
// whether it looks signed in, and which effort levels it accepts.
//
// Each CLI is one manifest (manifests/<name>.toml, overridable from
// ~/.config/afk/harnesses/), plus, where a sign-in check needs code, an
// entry in authChecks.
package harness

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

// Adapter describes one agent CLI.
type Adapter struct {
	// Name is AFK's id for the CLI, used in config and on the command line.
	Name string
	// Display is the name people know it by.
	Display string
	// Vendor is who makes it.
	Vendor string
	// Bins are the executable names to look for, in order.
	Bins []string
	// NPMPackage is the package name when the CLI is installed with a
	// JavaScript package manager. Empty when it is not shipped on npm.
	NPMPackage string
	// Efforts are the reasoning effort levels the CLI accepts, weakest
	// first. Empty when the CLI has no effort setting.
	Efforts []string
	// EffortFlag shows how the effort is passed, for people reading output.
	EffortFlag string
	// Login is the command a person runs to sign in again.
	Login string
	// SelfUpdate is the argument that makes a self-managed install update
	// itself (for example "update"). Empty when the CLI cannot.
	SelfUpdate string
	// Manifest is everything else the manifest says.
	Manifest Manifest
	// auth reports whether the CLI looks signed in. Nil when AFK has no
	// reliable way to tell; the answer is then "unknown", never a guess.
	auth func(e Env) (AuthState, string)
}

// SupportsEffort reports whether the CLI takes an effort level.
func (a Adapter) SupportsEffort() bool { return len(a.Efforts) > 0 }

// authChecks are the sign-in checks that need code, by harness. Every
// other fact about a harness is in its manifest.
var authChecks = map[string]func(e Env) (AuthState, string){
	"claude": claudeAuth,
	"codex":  codexAuth,
	// OpenCode always has its free models, signed in or not.
	"opencode": func(Env) (AuthState, string) { return AuthOK, "" },
	"grok":     nonEmptyFile(".grok", "auth.json"),
	"agy":      nonEmptyDir(".gemini", "antigravity-cli"),
	"gemini":   fileOrEnv([]string{".gemini", "oauth_creds.json"}, "GEMINI_API_KEY", "GOOGLE_API_KEY"),
	"qwen":     fileOrEnv([]string{".qwen", "oauth_creds.json"}, "DASHSCOPE_API_KEY"),
	"pi":       nonEmptyFile(".pi", "agent", "auth.json"),
	"devin":    nonEmptyFile(".local", "share", "devin", "credentials.toml"),
}

var registry []Adapter

func init() { rebuild() }

// rebuild makes the registry from the manifests.
func rebuild() {
	registry = registry[:0]
	for _, n := range order {
		m := manifests[n]
		login := strings.Join(m.Auth.Login, " ")
		if login == "" {
			login = m.LoginNote
		}
		registry = append(registry, Adapter{
			Name: m.Name, Display: m.Display, Vendor: m.Vendor, Bins: m.Bins, NPMPackage: m.NPMPackage,
			Efforts: m.Efforts, EffortFlag: m.EffortFlag, Login: login, SelfUpdate: m.SelfUpdate,
			Manifest: m, auth: authChecks[n],
		})
	}
}

// All returns every known adapter, in a stable order.
func All() []Adapter {
	out := make([]Adapter, len(registry))
	copy(out, registry)
	return out
}

// Lookup finds an adapter by its AFK name or by one of its executable names.
func Lookup(name string) (Adapter, bool) {
	for _, a := range registry {
		if a.Name == name {
			return a, true
		}
	}
	for _, a := range registry {
		for _, b := range a.Bins {
			if b == name {
				return a, true
			}
		}
	}
	return Adapter{}, false
}

// Names returns the AFK names of every known adapter, sorted.
func Names() []string {
	out := make([]string, 0, len(registry))
	for _, a := range registry {
		out = append(out, a.Name)
	}
	sort.Strings(out)
	return out
}

// Env is everything discovery reads from the machine. Tests replace it.
type Env struct {
	Home   string
	Path   string // the PATH list
	OS     string // runtime.GOOS
	Getenv func(string) string
	// BinDir, when set, is the only place binaries are looked for
	// (AFK_HARNESS_BIN_DIR, for tests and pinned images).
	BinDir string
}

// HostEnv reads the real machine.
func HostEnv() Env {
	home, _ := os.UserHomeDir()
	return Env{
		Home:   home,
		Path:   os.Getenv("PATH"),
		OS:     runtime.GOOS,
		Getenv: os.Getenv,
		BinDir: os.Getenv("AFK_HARNESS_BIN_DIR"),
	}
}

func (e Env) getenv(k string) string {
	if e.Getenv == nil {
		return ""
	}
	return e.Getenv(k)
}

func (e Env) home(parts ...string) string {
	return filepath.Join(append([]string{e.Home}, parts...)...)
}
