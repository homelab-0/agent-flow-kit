package harness

import (
	"encoding/json"
	"os"
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

// The checks below only test that a credential exists. They never read a
// token's value out of a file, and never print anything from one.

func claudeAuth(e Env) (AuthState, string) {
	if dir := e.getenv("CLAUDE_CONFIG_DIR"); dir != "" {
		if st, why := claudeCreds(dir + "/.credentials.json"); st == AuthOK {
			return st, why
		}
	}
	st, why := claudeCreds(e.home(".claude", ".credentials.json"))
	if st != AuthOK && e.OS == "darwin" {
		// On macOS Claude Code keeps its login in the Keychain, which
		// AFK does not read.
		return AuthUnknown, "the login is in the macOS Keychain"
	}
	return st, why
}

func claudeCreds(path string) (AuthState, string) {
	var v struct {
		OAuth *struct {
			Access  string `json:"accessToken"`
			Refresh string `json:"refreshToken"`
		} `json:"claudeAiOauth"`
	}
	if !readJSON(path, &v) || v.OAuth == nil || (v.OAuth.Access == "" && v.OAuth.Refresh == "") {
		return AuthSignedOut, "no Claude login found"
	}
	return AuthOK, ""
}

func codexAuth(e Env) (AuthState, string) {
	home := e.getenv("CODEX_HOME")
	if home == "" {
		home = e.home(".codex")
	}
	var v struct {
		Key    string `json:"OPENAI_API_KEY"`
		Tokens *struct {
			Access  string `json:"access_token"`
			Refresh string `json:"refresh_token"`
			Account string `json:"account_id"`
		} `json:"tokens"`
	}
	if readJSON(home+"/auth.json", &v) {
		if v.Key != "" || (v.Tokens != nil && (v.Tokens.Access != "" || v.Tokens.Refresh != "" || v.Tokens.Account != "")) {
			return AuthOK, ""
		}
	}
	return AuthSignedOut, "no Codex login found"
}

// nonEmptyJSONObject: signed in when the file holds a JSON object with at
// least one key.
func nonEmptyJSONObject(parts ...string) func(Env) (AuthState, string) {
	return func(e Env) (AuthState, string) {
		var v map[string]json.RawMessage
		if readJSON(e.home(parts...), &v) && len(v) > 0 {
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
		if err == nil && len(ents) > 0 {
			return AuthOK, ""
		}
		return AuthSignedOut, "no login found"
	}
}

func nonEmptyFile(parts ...string) func(Env) (AuthState, string) {
	return func(e Env) (AuthState, string) {
		if fi, err := os.Stat(e.home(parts...)); err == nil && fi.Mode().IsRegular() && fi.Size() > 0 {
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

func readJSON(path string, v any) bool {
	b, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return json.Unmarshal(b, v) == nil
}
