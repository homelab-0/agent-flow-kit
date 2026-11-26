package config

import (
	"errors"
	"regexp"
	"strings"
)

// SecretRef is where a secret lives, never the secret itself:
//
//	env:NAME          an environment variable
//	file:/abs/path    a file only you can read
//	cmd:program args  a command that prints it
//	op://vault/item   a 1Password reference
//	keychain:NAME     the OS keychain
//
// Config holds only the reference. It is resolved at the moment the
// secret is used, by the code that uses it, and the value is never
// written to disk or printed.
type SecretRef struct {
	Kind string // env, file, cmd, op, keychain
	Arg  string // the name, path, command line or op:// address
}

var envNameRE = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)

// ErrNotReference is a config value that looks like a secret itself.
var ErrNotReference = errors.New(`must be a reference (env:NAME, file:/path, cmd:..., op://..., keychain:NAME), never the secret itself`)

// ParseSecretRef reads a reference. The error never repeats the value, in
// case it is a pasted key.
func ParseSecretRef(s string) (SecretRef, error) {
	switch {
	case strings.HasPrefix(s, "env:"):
		n := strings.TrimPrefix(s, "env:")
		if !envNameRE.MatchString(n) {
			return SecretRef{}, errors.New("env: needs a variable name")
		}
		return SecretRef{Kind: "env", Arg: n}, nil
	case strings.HasPrefix(s, "file:"):
		p := strings.TrimPrefix(s, "file:")
		if !strings.HasPrefix(p, "/") && !strings.HasPrefix(p, "~/") {
			return SecretRef{}, errors.New("file: needs an absolute path")
		}
		return SecretRef{Kind: "file", Arg: p}, nil
	case strings.HasPrefix(s, "cmd:"):
		c := strings.TrimSpace(strings.TrimPrefix(s, "cmd:"))
		if c == "" {
			return SecretRef{}, errors.New("cmd: needs a command")
		}
		return SecretRef{Kind: "cmd", Arg: c}, nil
	case strings.HasPrefix(s, "op://"):
		if len(strings.Split(strings.TrimPrefix(s, "op://"), "/")) < 2 {
			return SecretRef{}, errors.New("op:// needs a vault and an item")
		}
		return SecretRef{Kind: "op", Arg: s}, nil
	case strings.HasPrefix(s, "keychain:"):
		if strings.TrimPrefix(s, "keychain:") == "" {
			return SecretRef{}, errors.New("keychain: needs a name")
		}
		return SecretRef{Kind: "keychain", Arg: strings.TrimPrefix(s, "keychain:")}, nil
	}
	return SecretRef{}, ErrNotReference
}

func (r SecretRef) String() string {
	if r.Kind == "op" {
		return r.Arg
	}
	return r.Kind + ":" + r.Arg
}
