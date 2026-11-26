// Package launch starts the chosen CLI from an engine launch plan as a
// foreground child of afk, and waits for it.
package launch

import (
	"fmt"
	"os"
	"regexp"
	"sort"
	"strings"
)

var (
	envName = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	// A gateway key may never come from a vendor's own variables: those can
	// hold a plan login, and a plan login never goes to a gateway.
	vendorPrefix = regexp.MustCompile(`^(CLAUDE_|ANTHROPIC_|OPENAI_|CODEX_|XAI_|GROK_|GEMINI_|GOOGLE_|OPENCODE_)`)
)

// EnvError is a plan whose environment afk refuses to build. It names the
// variable, never its value.
type EnvError struct{ Msg string }

func (e *EnvError) Error() string { return e.Msg }

// BuildEnv is the child's environment, built the way the engine's
// afk_cli_apply_plan_env does it:
//
//  1. every env_from source is read from base first, so an env_unset entry
//     can never empty one;
//  2. env_unset is removed;
//  3. env_set is applied;
//  4. the env_from targets are set from the values read in step 1.
//
// A source that is empty, is not a variable name, or is a vendor variable
// (CLAUDE_, ANTHROPIC_, OPENAI_, …) refuses the launch. Copied values are
// returned only inside the environment, so they cannot reach a log.
func BuildEnv(base []string, set map[string]string, from map[string]string, unset []string) ([]string, error) {
	vals := make(map[string]string, len(base))
	var order []string
	for _, kv := range base {
		k, v, ok := strings.Cut(kv, "=")
		if !ok {
			continue
		}
		if _, seen := vals[k]; !seen {
			order = append(order, k)
		}
		vals[k] = v
	}
	type pair struct{ k, v string }
	var copies []pair
	for _, k := range sortedKeys(from) {
		name := from[k]
		if !envName.MatchString(k) || !envName.MatchString(name) {
			return nil, &EnvError{fmt.Sprintf("the launch plan names %q as a variable to copy from, which is not a variable name", name)}
		}
		if vendorPrefix.MatchString(name) {
			return nil, &EnvError{fmt.Sprintf("the gateway key cannot come from $%s: vendor variables can hold a plan login, and a plan login never goes to a gateway", name)}
		}
		v := vals[name]
		if v == "" {
			return nil, &EnvError{fmt.Sprintf("$%s is empty; export the gateway key in it first", name)}
		}
		copies = append(copies, pair{k, v})
	}
	for _, k := range unset {
		delete(vals, k)
	}
	put := func(k, v string) {
		if _, ok := vals[k]; !ok {
			order = append(order, k)
		}
		vals[k] = v
	}
	for _, k := range sortedKeys(set) {
		if !envName.MatchString(k) {
			return nil, &EnvError{fmt.Sprintf("the launch plan sets %q, which is not a variable name", k)}
		}
		put(k, set[k])
	}
	for _, c := range copies {
		put(c.k, c.v)
	}
	out := make([]string, 0, len(vals))
	for _, k := range order {
		if v, ok := vals[k]; ok {
			out = append(out, k+"="+v)
			delete(vals, k)
		}
	}
	return out, nil
}

func sortedKeys(m map[string]string) []string {
	ks := make([]string, 0, len(m))
	for k := range m {
		ks = append(ks, k)
	}
	sort.Strings(ks)
	return ks
}

// PrepareDirs creates the private config directory a plan points the CLI at
// (CLAUDE_CONFIG_DIR for a gateway launch), as the bash engine does.
func PrepareDirs(set map[string]string) {
	if d := set["CLAUDE_CONFIG_DIR"]; d != "" {
		_ = os.MkdirAll(d, 0o700)
		_ = os.Chmod(d, 0o700)
	}
}
