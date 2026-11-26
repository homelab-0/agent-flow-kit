package harness

import (
	"bytes"
	"context"
	"errors"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// AuthState is whether a CLI looks signed in, from what it keeps on disk.
// It says nothing about whether the credential still works: only a real
// request proves that.
type AuthState string

const (
	AuthOK           AuthState = "authenticated"
	AuthSignedOut    AuthState = "signed_out"
	AuthUnknown      AuthState = "unknown"
	AuthNotInstalled AuthState = "not_installed"
)

// The checks below only test that a login is there: a credential file
// exists and is not empty, a state directory has something in it, or an
// API key variable is set. AFK never opens a credential file, so no token
// is ever read, printed, logged, stored or sent anywhere. A file AFK can't
// stat (permissions, I/O errors) gives "unknown", not "signed_out".

func claudeAuth(e Env) (AuthState, string) {
	// Claude Code reads its login from CLAUDE_CONFIG_DIR when that is set,
	// and from ~/.claude otherwise. Only the selected directory counts.
	path := e.home(".claude", ".credentials.json")
	if dir := e.getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		path = filepath.Join(dir, ".credentials.json")
	}
	st, why := fileState(path, "Claude ")
	if st == AuthSignedOut && e.OS == "darwin" {
		// On macOS Claude Code keeps its login in the Keychain, which
		// AFK does not read.
		return AuthUnknown, "the login is in the macOS Keychain"
	}
	return st, why
}

func codexAuth(e Env) (AuthState, string) {
	home := e.getenv("CODEX_HOME")
	if home == "" {
		home = e.home(".codex")
	}
	return fileState(filepath.Join(home, "auth.json"), "Codex ")
}

// fileState: signed in when the login file exists and is bigger than an
// empty JSON object. Only the file's metadata is looked at.
func fileState(path, who string) (AuthState, string) {
	fi, err := os.Stat(path)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return AuthSignedOut, "no " + who + "login found"
	case err != nil:
		return AuthUnknown, "could not check the " + who + "login file"
	case fi.Mode().IsRegular() && fi.Size() > MinLoginSize:
		return AuthOK, ""
	}
	return AuthSignedOut, "no " + who + "login found"
}

// MinLoginSize is the largest file that can't hold a login: a CLI that
// signed out often leaves "{}" (or "{}\n") behind. Every real login file is
// far bigger. Size is metadata: the file is still never opened.
const MinLoginSize = 4

// nonEmptyDir: signed in when the CLI has written anything to its state
// directory. An install that never logged in leaves it missing or empty.
func nonEmptyDir(parts ...string) func(Env) (AuthState, string) {
	return func(e Env) (AuthState, string) {
		ents, err := os.ReadDir(e.home(parts...))
		switch {
		case errors.Is(err, fs.ErrNotExist):
			return AuthSignedOut, "no login found"
		case err != nil:
			return AuthUnknown, "could not read the login directory"
		case len(ents) > 0:
			return AuthOK, ""
		}
		return AuthSignedOut, "no login found"
	}
}

func nonEmptyFile(parts ...string) func(Env) (AuthState, string) {
	return func(e Env) (AuthState, string) { return fileState(e.home(parts...), "") }
}

// fileOrEnv: signed in when the OAuth file exists or one of the API key
// variables is set. Without either the answer is unknown, because these
// CLIs also accept logins AFK cannot see.
func fileOrEnv(file []string, vars ...string) func(Env) (AuthState, string) {
	return func(e Env) (AuthState, string) {
		for _, k := range vars {
			if e.getenv(k) != "" {
				return AuthOK, k + " is set"
			}
		}
		// The same rule as every other login file: larger than an empty
		// JSON object, never opened.
		if fi, err := os.Stat(e.home(file...)); err == nil && fi.Mode().IsRegular() && fi.Size() > MinLoginSize {
			return AuthOK, ""
		}
		return AuthUnknown, "no login file or API key variable found"
	}
}

// CodexLoginMode asks Codex how it is signed in (`codex login status`):
// "chatgpt" for the ChatGPT plan, "apikey" for an API key, "" when it can't
// tell. Only those words are looked for; the rest of the answer is dropped
// without being kept or printed.
func CodexLoginMode(ctx context.Context, e Env) string {
	a, ok := Lookup("codex")
	if !ok {
		return ""
	}
	bin := Locate(e, a)
	if bin == "" {
		return ""
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, bin, "login", "status")
	var out bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &out
	cmd.WaitDelay = time.Second
	_ = cmd.Run()
	mode := ClassifyCodexLogin(out.String())
	out.Reset()
	return mode
}

// ClassifyCodexLogin reads `codex login status` output.
func ClassifyCodexLogin(s string) string {
	l := strings.ToLower(s)
	switch {
	case strings.Contains(l, "not logged in"):
		return ""
	case strings.Contains(l, "api key"):
		return "apikey"
	case strings.Contains(l, "chatgpt"):
		return "chatgpt"
	}
	return ""
}
