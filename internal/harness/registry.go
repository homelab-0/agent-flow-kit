// Package harness knows the agent CLIs AFK can drive: where each one is
// installed, what version it is, how it was installed and how to update it,
// whether it looks signed in, and which effort levels it accepts.
//
// Each CLI is one Adapter in the registry below. Supporting a new CLI means
// adding one entry; nothing else in AFK lists harness names.
package harness

import (
	"os"
	"path/filepath"
	"runtime"
	"sort"
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
	// auth reports whether the CLI looks signed in. Nil when AFK has no
	// reliable way to tell; the answer is then "unknown", never a guess.
	auth func(e Env) (AuthState, string)
}

// SupportsEffort reports whether the CLI takes an effort level.
func (a Adapter) SupportsEffort() bool { return len(a.Efforts) > 0 }

var registry = []Adapter{
	{
		Name: "claude", Display: "Claude Code", Vendor: "Anthropic",
		Bins: []string{"claude"}, NPMPackage: "@anthropic-ai/claude-code",
		Efforts: []string{"low", "medium", "high", "xhigh", "max"}, EffortFlag: "--effort <level>",
		Login: "claude auth login", SelfUpdate: "update",
		auth: claudeAuth,
	},
	{
		Name: "codex", Display: "Codex CLI", Vendor: "OpenAI",
		Bins: []string{"codex"}, NPMPackage: "@openai/codex",
		Efforts: []string{"low", "medium", "high", "xhigh", "max", "ultra"}, EffortFlag: "-c model_reasoning_effort=<level>",
		Login: "codex login",
		auth:  codexAuth,
	},
	{
		Name: "opencode", Display: "OpenCode", Vendor: "SST",
		Bins: []string{"opencode"}, NPMPackage: "opencode-ai",
		Efforts: []string{"low", "medium", "high"}, EffortFlag: "--variant <level>",
		Login: "opencode auth login", SelfUpdate: "upgrade",
		// OpenCode always has its free models, signed in or not.
		auth: func(Env) (AuthState, string) { return AuthOK, "" },
	},
	{
		Name: "grok", Display: "Grok CLI", Vendor: "xAI",
		Bins:    []string{"grok"},
		Efforts: []string{"low", "medium", "high", "xhigh"}, EffortFlag: "--effort <level>",
		Login: "grok login", SelfUpdate: "update",
		auth: nonEmptyFile(".grok", "auth.json"),
	},
	{
		Name: "agy", Display: "Antigravity CLI", Vendor: "Google",
		Bins:    []string{"agy"},
		Efforts: []string{"low", "medium", "high", "xhigh", "max"}, EffortFlag: "--effort <level>",
		Login: "agy login", SelfUpdate: "update",
		auth: nonEmptyDir(".gemini", "antigravity-cli"),
	},
	{
		Name: "gemini", Display: "Gemini CLI", Vendor: "Google",
		Bins: []string{"gemini"}, NPMPackage: "@google/gemini-cli",
		Login: "gemini",
		auth:  fileOrEnv([]string{".gemini", "oauth_creds.json"}, "GEMINI_API_KEY", "GOOGLE_API_KEY"),
	},
	{
		Name: "copilot", Display: "GitHub Copilot CLI", Vendor: "GitHub",
		Bins: []string{"copilot"}, NPMPackage: "@github/copilot",
		Login: "copilot (then /login)",
	},
	{
		Name: "cursor", Display: "Cursor Agent", Vendor: "Cursor",
		Bins:  []string{"cursor-agent"},
		Login: "cursor-agent login", SelfUpdate: "update",
	},
	{
		Name: "kiro", Display: "Kiro CLI", Vendor: "AWS",
		Bins:  []string{"kiro-cli"},
		Login: "kiro-cli login",
	},
	{
		Name: "qwen", Display: "Qwen Code", Vendor: "Alibaba",
		Bins: []string{"qwen"}, NPMPackage: "@qwen-code/qwen-code",
		Login: "qwen",
		auth:  fileOrEnv([]string{".qwen", "oauth_creds.json"}, "DASHSCOPE_API_KEY"),
	},
	{
		Name: "kimi", Display: "Kimi Code", Vendor: "Moonshot AI",
		Bins: []string{"kimi"}, NPMPackage: "@moonshot-ai/kimi-code",
		Login: "kimi",
	},
	{
		Name: "pi", Display: "Pi", Vendor: "Mario Zechner",
		Bins: []string{"pi"}, NPMPackage: "@mariozechner/pi-coding-agent",
		Efforts: []string{"low", "medium", "high", "xhigh", "max"}, EffortFlag: "--thinking <level>",
		Login: "pi (then /login)",
		auth:  nonEmptyFile(".pi", "agent", "auth.json"),
	},
	{
		Name: "devin", Display: "Devin CLI", Vendor: "Cognition",
		Bins:    []string{"devin"},
		Efforts: []string{"low", "medium", "high", "xhigh", "max"}, EffortFlag: "--model <id>-<level>",
		Login: "devin auth login",
		auth:  nonEmptyFile(".local", "share", "devin", "credentials.toml"),
	},
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
