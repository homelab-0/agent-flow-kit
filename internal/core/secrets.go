package core

import (
	"sort"

	"github.com/jlengelbrecht/agent-flow-kit/internal/config"
)

// ownSecretVars are the variables that hold AFK's own secrets and are set
// right now: the gateway key ($AFK_GATEWAY_KEY, or the variable
// AFK_GATEWAY_KEY_ENV names) and every config.toml gateway's key =
// "env:NAME". A CLI has no use for them: a gateway launch gets its key as
// ANTHROPIC_AUTH_TOKEN, copied before anything is removed. Left in place,
// any command the agent runs could read a key that works on every model
// behind the gateway, so a launch removes them. AFK_KEEP_SECRETS=1 leaves
// the environment alone, for a CLI that calls afk itself.
//
// A vendor's own variable is never in the list, whatever config names: the
// CLI may need it, and what a CLI does with its own credentials is yours
// to decide.
func (c *Core) ownSecretVars() []string {
	if truthyEnv(c.getenv("AFK_KEEP_SECRETS")) {
		return nil
	}
	names := map[string]bool{"AFK_GATEWAY_KEY": true}
	if v := c.getenv("AFK_GATEWAY_KEY_ENV"); v != "" {
		names[v] = true
	}
	if s, err := c.LoadSettings(""); err == nil {
		for _, g := range s.Gateways {
			if ref, err := config.ParseSecretRef(g.Key); err == nil && ref.Kind == "env" {
				names[ref.Arg] = true
			}
		}
	}
	var out []string
	for n := range names {
		if gatewayKeyVarOK(n) && c.getenv(n) != "" {
			out = append(out, n)
		}
	}
	sort.Strings(out)
	return out
}

func truthyEnv(v string) bool { return v == "true" || v == "1" }
