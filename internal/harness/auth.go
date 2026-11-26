package harness

import (
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
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

// The checks below only test that a credential exists. Where a check has
// to look inside a credential file, it decodes only the field names and
// whether each value is empty: token values are never decoded into
// strings, printed, logged or stored. A file AFK can't read (permissions,
// I/O errors, malformed JSON) gives "unknown", not "signed_out", because
// the check could not tell whether a login is there.

func claudeAuth(e Env) (AuthState, string) {
	// Claude Code reads its login from CLAUDE_CONFIG_DIR when that is set,
	// and from ~/.claude otherwise. Only the selected directory counts.
	path := e.home(".claude", ".credentials.json")
	if dir := e.getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		path = filepath.Join(dir, ".credentials.json")
	}
	st, why := claudeCreds(path)
	if st == AuthSignedOut && e.OS == "darwin" {
		// On macOS Claude Code keeps its login in the Keychain, which
		// AFK does not read.
		return AuthUnknown, "the login is in the macOS Keychain"
	}
	return st, why
}

func claudeCreds(path string) (AuthState, string) {
	var v struct {
		OAuth map[string]json.RawMessage `json:"claudeAiOauth"`
	}
	switch err := readJSON(path, &v); {
	case errors.Is(err, fs.ErrNotExist):
		return AuthSignedOut, "no Claude login found"
	case err != nil:
		return AuthUnknown, "could not read the Claude login file"
	}
	if present(v.OAuth["accessToken"]) || present(v.OAuth["refreshToken"]) {
		return AuthOK, ""
	}
	return AuthSignedOut, "no Claude login found"
}

func codexAuth(e Env) (AuthState, string) {
	home := e.getenv("CODEX_HOME")
	if home == "" {
		home = e.home(".codex")
	}
	var v struct {
		Key    json.RawMessage            `json:"OPENAI_API_KEY"`
		Tokens map[string]json.RawMessage `json:"tokens"`
	}
	switch err := readJSON(filepath.Join(home, "auth.json"), &v); {
	case errors.Is(err, fs.ErrNotExist):
		return AuthSignedOut, "no Codex login found"
	case err != nil:
		return AuthUnknown, "could not read the Codex login file"
	}
	if present(v.Key) || present(v.Tokens["access_token"]) || present(v.Tokens["refresh_token"]) || present(v.Tokens["account_id"]) {
		return AuthOK, ""
	}
	return AuthSignedOut, "no Codex login found"
}

// present reports whether a raw JSON value is set: not missing, not null
// and not an empty string. It never decodes the value itself.
func present(raw json.RawMessage) bool {
	t := strings.TrimSpace(string(raw))
	return t != "" && t != "null" && t != `""`
}

// nonEmptyJSONObject: signed in when the file holds a JSON object with at
// least one key.
func nonEmptyJSONObject(parts ...string) func(Env) (AuthState, string) {
	return func(e Env) (AuthState, string) {
		var v map[string]json.RawMessage
		switch err := readJSON(e.home(parts...), &v); {
		case errors.Is(err, fs.ErrNotExist):
			return AuthSignedOut, "no login found"
		case err != nil:
			return AuthUnknown, "could not read the login file"
		case len(v) > 0:
			return AuthOK, ""
		}
		return AuthSignedOut, "no login found"
	}
}

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
	return func(e Env) (AuthState, string) {
		fi, err := os.Stat(e.home(parts...))
		switch {
		case errors.Is(err, fs.ErrNotExist):
			return AuthSignedOut, "no login found"
		case err != nil:
			return AuthUnknown, "could not read the login file"
		case fi.Mode().IsRegular() && fi.Size() > 0:
			return AuthOK, ""
		}
		return AuthSignedOut, "no login found"
	}
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
		if fi, err := os.Stat(e.home(file...)); err == nil && fi.Size() > 0 {
			return AuthOK, ""
		}
		return AuthUnknown, "no login file or API key variable found"
	}
}

// readJSON decodes a JSON file. A missing file returns an error wrapping
// fs.ErrNotExist; any other failure (permissions, I/O, bad JSON) returns
// a different error, so callers can tell "absent" from "can't tell".
func readJSON(path string, v any) error {
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err := json.Unmarshal(b, v); err != nil {
		return fmt.Errorf("%s: %w", path, err)
	}
	return nil
}
