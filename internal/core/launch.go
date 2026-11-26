package core

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/jlengelbrecht/agent-flow-kit/internal/config"
	"github.com/jlengelbrecht/agent-flow-kit/internal/engine"
	"github.com/jlengelbrecht/agent-flow-kit/internal/harness"
)

var (
	envNameRE    = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
	vendorVarRE  = regexp.MustCompile(`^(CLAUDE_|ANTHROPIC_|OPENAI_|CODEX_|XAI_|GROK_|GEMINI_|GOOGLE_|OPENCODE_)`)
	planPoolRE   = regexp.MustCompile(`^(anthropic-max|openai-plus|xai-grok|antigravity-pool)$|-oauth$`)
	effortTierRE = regexp.MustCompile(`-(low|medium|high)$`)
)

// knownVendorVars are the Claude/Anthropic credential variables, unset for
// a gateway launch so the plan login never reaches the gateway.
var knownVendorVars = []string{
	"ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
	"CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR", "CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR", "CLAUDE_CODE_SESSION_ACCESS_TOKEN",
	"CLAUDE_CODE_SESSIONS_OAUTH_TOKEN", "ANTHROPIC_IDENTITY_TOKEN", "ANTHROPIC_IDENTITY_TOKEN_FILE", "ANTHROPIC_CUSTOM_HEADERS",
	"CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX", "CLAUDE_CODE_USE_FOUNDRY",
}

// gatewayKeyVarOK: the gateway key must come from a plain variable that is
// not a vendor credential, so a plan token can never pass as the key.
func gatewayKeyVarOK(name string) bool {
	return envNameRE.MatchString(name) && !vendorVarRE.MatchString(name)
}

// planError is a launch plan that refuses, with the reason.
func planError(msg string) (*engine.LaunchPlan, error) {
	return nil, &engine.PlanError{Reason: msg}
}

// LaunchPlan works out how to start a route: the command, the environment
// it needs and where its answer goes. Every launch passes here, so the
// gateway rule is checked here too, for pinned routes and routes a front
// end chose: a plan login is never sent through a gateway.
// perm is the permission mode asked for ("" is ask). When the CLI can't do
// it, the next stricter mode it can do is used and the plan says so; a CLI
// that can do nothing as strict is refused.
func (c *Core) LaunchPlan(_ context.Context, r engine.Route, mode string, perm string, pass []string, prompt string) (*engine.LaunchPlan, error) {
	h, m, e := r.Harness, r.Model, r.Effort
	if mode != "interactive" && mode != "print" {
		return nil, &UsageError{"--mode must be interactive or print"}
	}
	if h == "" {
		return nil, &UsageError{"the launch plan needs a route with a harness"}
	}
	if mode == "print" && prompt == "" {
		return nil, &UsageError{"a print plan needs a prompt"}
	}
	cclass, pool := r.CostClass, r.EntitlementPool
	// Which CLI runs which model with which login is your choice; AFK
	// launches what you route to. The one refusal left is credential
	// safety: a plan login is never sent to a gateway (another party's
	// server).
	if strings.HasSuffix(r.LaunchClass, "-gateway") && (cclass == "subscription" || planPoolRE.MatchString(pool)) {
		return planError("the " + pool + " plan login is never sent through a gateway")
	}

	if perm == "" {
		perm = "ask"
	}
	man, ok := harness.ManifestFor(h)
	if !ok {
		return planError("no launch for " + h + " here (is it installed?)")
	}
	// The CLI's own skip-permissions flag given through --pass is yolo,
	// so it gets the same trust check, and the plan says yolo.
	passNote := ""
	if perm != "yolo" && man.YoloIn(pass) {
		perm, passNote = "yolo", "--pass gave "+h+"'s own skip-permissions flag, so this runs as yolo"
	}
	// Trust is checked again for every yolo plan (a retry, or a card
	// left open while trust was removed), against the settings now.
	if perm == "yolo" {
		if err := c.checkYolo(); err != nil {
			return nil, err
		}
		if d := man.DirIn(pass); d != "" {
			return nil, &UsageError{"yolo checks trust for the directory afk runs in, so it can't take " + h + "'s " + d + " in --pass; run afk from that directory instead"}
		}
	}
	modeFlags, ran, modeNote, ok := man.ModeFlags(perm, mode == "print")
	if !ok {
		if modeNote == "" {
			modeNote = perm + " is not a permission mode (read-only, ask, edits, auto or yolo)"
		}
		return planError(modeNote)
	}
	if passNote != "" {
		modeNote = passNote
	}

	set, from, unset, err := c.launchEnv(r)
	if err != nil {
		return planError(err.Error())
	}
	cxout := ""
	if mode == "print" && h == "codex" {
		f, err := os.CreateTemp("", "afk-cli-cx.*")
		if err != nil {
			return nil, err
		}
		cxout = f.Name()
		f.Close()
	}
	argv := c.launchArgv(h, m, e, mode, modeFlags, prompt, cxout, pass)
	if argv == nil {
		if cxout != "" {
			os.Remove(cxout)
		}
		return planError("no launch for " + h + " here (is it installed?)")
	}
	var answer json.RawMessage = []byte("null")
	if mode == "print" {
		if h == "codex" {
			answer, _ = json.Marshal(map[string]any{"format": "text-file", "file": cxout})
		} else {
			answer = []byte(`{"format":"json","file":null}`)
		}
	}
	cwd := c.Cwd
	if cwd == "" {
		cwd, _ = os.Getwd()
	}
	return &engine.LaunchPlan{
		Schema: engine.SchemaLaunchPlan, OK: true, Argv: argv,
		EnvSet: set, EnvFrom: from, EnvUnset: unset, Cwd: cwd, Answer: answer,
		Mode: ran, ModeNote: modeNote,
	}, nil
}

// launchEnv is the environment a route needs. A gateway route runs claude
// against the gateway with the gateway's own key, from a config directory
// of its own, with every Claude/Anthropic variable unset, so the plan login
// is never sent to the gateway. env_from names the variable a secret is
// copied from at spawn time; no secret value is ever in the plan.
func (c *Core) launchEnv(r engine.Route) (set, from map[string]string, unset []string, err error) {
	set, from, unset = map[string]string{}, map[string]string{}, []string{}
	if !strings.HasSuffix(r.LaunchClass, "-gateway") {
		return set, from, unset, nil
	}
	if r.LitellmBaseURL == "" {
		return nil, nil, nil, &UsageError{"this route goes through the model gateway and none is configured (set AFK_LITELLM_BASE_URL)"}
	}
	if r.Harness != "claude" {
		return nil, nil, nil, &UsageError{r.Harness + " cannot use the gateway without exposing its own plan login"}
	}
	// The key's variable. AFK_GATEWAY_KEY_ENV is the explicit override.
	// Otherwise a gateway's key only ever goes to that gateway's own url:
	// the config.toml gateway whose url is the route's supplies its key =
	// "env:NAME". A route whose url no config.toml gateway declares (a
	// route made before the config changed, or from elsewhere) is refused
	// rather than given another gateway's key; the address from
	// AFK_LITELLM_BASE_URL (or an older router.json) keeps AFK_GATEWAY_KEY.
	// Only the variable's name is in the plan; the value is copied at spawn
	// time.
	keyVar := c.getenv("AFK_GATEWAY_KEY_ENV")
	if keyVar == "" {
		s, err := c.LoadSettings("")
		if err != nil {
			return nil, nil, nil, err
		}
		name, g, found := s.GatewayFor(r.LitellmBaseURL)
		switch {
		case found && g.Key != "":
			ref, err := config.ParseSecretRef(g.Key)
			if err != nil {
				return nil, nil, nil, &UsageError{"gateway " + name + ": " + err.Error()}
			}
			if ref.Kind != "env" {
				return nil, nil, nil, &UsageError{"gateway " + name + ": a key from " + ref.Kind + ": can't be used to launch yet; use key = \"env:NAME\""}
			}
			keyVar = ref.Arg
		case found:
			keyVar = "AFK_GATEWAY_KEY"
		case len(s.Gateways) > 0 && strings.TrimRight(r.LitellmBaseURL, "/") != strings.TrimRight(c.getenv("AFK_LITELLM_BASE_URL"), "/"):
			var urls []string
			for _, n := range sortedNames(s.Gateways) {
				urls = append(urls, n+" = "+s.Gateways[n].URL)
			}
			return nil, nil, nil, &UsageError{"the route's gateway " + redactedURL(r.LitellmBaseURL) + " is not one config.toml defines (" + strings.Join(urls, ", ") + "); route again so the gateway's own key is used"}
		default:
			keyVar = "AFK_GATEWAY_KEY"
		}
	}
	if !gatewayKeyVarOK(keyVar) {
		return nil, nil, nil, &UsageError{"AFK_GATEWAY_KEY_ENV must name a plain variable that is not a vendor credential (not CLAUDE_*, ANTHROPIC_*, OPENAI_*, ...)"}
	}
	if c.getenv(keyVar) == "" {
		return nil, nil, nil, &UsageError{"the gateway needs its key in $" + keyVar + " (export it, or name another variable in AFK_GATEWAY_KEY_ENV)"}
	}
	state := c.getenv("AFK_STATE_DIR")
	if state == "" {
		state = filepath.Join(c.Home, ".local", "state", "agent-flow-kit")
	}
	names := map[string]bool{}
	for _, n := range knownVendorVars {
		names[n] = true
	}
	environ := os.Environ
	if c.Environ != nil {
		environ = c.Environ
	}
	for _, kv := range environ() {
		n, _, _ := strings.Cut(kv, "=")
		if strings.HasPrefix(n, "CLAUDE_CODE_") || strings.HasPrefix(n, "ANTHROPIC_") {
			names[n] = true
		}
	}
	delete(names, "ANTHROPIC_BASE_URL")
	delete(names, "ANTHROPIC_AUTH_TOKEN")
	for n := range names {
		unset = append(unset, n)
	}
	sort.Strings(unset)
	set["ANTHROPIC_BASE_URL"] = r.LitellmBaseURL
	set["CLAUDE_CONFIG_DIR"] = filepath.Join(state, "gateway-claude")
	from["ANTHROPIC_AUTH_TOKEN"] = keyVar
	return set, from, unset, nil
}

func sortedNames(m map[string]config.Gateway) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

// redactedURL is an address without any user info, for messages.
func redactedURL(s string) string {
	r := engine.Route{LitellmBaseURL: s}.Redacted()
	return r.LitellmBaseURL
}

// launchArgv is the command for a route. In print mode each CLI writes
// JSON, so errors reported with exit 0 are still seen. Arguments passed
// through go before the prompt, so a CLI never reads them as prompt text.
func (c *Core) launchArgv(h, model, effort, mode string, modeFlags []string, prompt, cxout string, pass []string) []string {
	a, ok := harness.Lookup(h)
	if !ok {
		return nil
	}
	bin := harness.Locate(c.Harness, a)
	if bin == "" {
		return nil
	}
	// A prompt that starts with a dash would be read as an option.
	if strings.HasPrefix(prompt, "-") {
		prompt = " " + prompt
	}
	print := mode == "print"
	argv := []string{bin}
	add := func(s ...string) { argv = append(argv, s...) }
	switch h {
	case "claude":
		if model != "" {
			add("--model", model)
		}
		if effort != "" {
			add("--effort", effort)
		}
		add(modeFlags...)
		if print {
			add("-p", "--output-format", "json")
		}
		add(pass...)
		if prompt != "" {
			add("--", prompt)
		}
	case "codex":
		if print {
			add("exec", "--skip-git-repo-check", "--json", "-o", cxout)
		}
		if model != "" {
			add("-m", model)
		}
		if effort != "" {
			add("-c", `model_reasoning_effort="`+effort+`"`)
		}
		add(modeFlags...)
		add(pass...)
		if prompt != "" {
			add("--", prompt)
		}
	case "opencode":
		if print {
			add("run", "--format", "json")
			if model != "" {
				add("-m", model)
			}
			add(modeFlags...)
			add(pass...)
			add("--", prompt)
		} else {
			if model != "" {
				add("-m", model)
			}
			add(modeFlags...)
			add(pass...)
			if prompt != "" {
				add("--prompt=" + prompt)
			}
		}
	case "grok":
		if model != "" {
			add("-m", model)
		}
		if effort != "" {
			add("--effort", effort)
		}
		add(modeFlags...)
		if print {
			add("--output-format", "json")
			add(pass...)
			add("--single=" + prompt)
		} else {
			add(pass...)
			if prompt != "" {
				add("--", prompt)
			}
		}
	case "agy":
		m := model
		// Antigravity model names carry the effort tier; keep it in step.
		if m != "" && (effort == "low" || effort == "medium" || effort == "high") {
			m = effortTierRE.ReplaceAllString(m, "") + "-" + effort
		}
		if m != "" {
			add("--model", m)
		}
		if effort != "" {
			add("--effort", effort)
		}
		add(modeFlags...)
		if print {
			add("--output-format", "json")
			add(pass...)
			add("-p", prompt)
		} else {
			add(pass...)
			if prompt != "" {
				add("-i", prompt)
			}
		}
	case "pi":
		if model != "" {
			add("--model", model)
		}
		if effort != "" {
			add("--thinking", effort)
		}
		// Pi never asks; its modes are tool allowlists.
		add(modeFlags...)
		if print {
			add("-p", "--mode", "json")
		}
		add(pass...)
		if prompt != "" {
			add("--", prompt)
		}
	default:
		return nil
	}
	return argv
}
