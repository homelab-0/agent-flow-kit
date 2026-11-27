# Model gateways

A model gateway serves models through one API: a proxy such as LiteLLM in front of local GPUs, OpenRouter, or a company endpoint. AFK can route work to a gateway model when it scores best, while keeping your plan logins away from the gateway.

## Today: one gateway, through Claude Code

Point AFK at a gateway that speaks the Anthropic Messages API, and give it the gateway's key:

```sh
export AFK_LITELLM_BASE_URL="http://gateway.local:4000"
export AFK_GATEWAY_KEY="..."              # the key, in the default variable
```

Or keep the key in a variable of your own and tell AFK its name. The two are alternatives: when `AFK_GATEWAY_KEY_ENV` is set, only the variable it names is read.

```sh
export MY_GATEWAY_KEY="..."
export AFK_GATEWAY_KEY_ENV="MY_GATEWAY_KEY"
```

The gateway can also be added without leaving AFK: the Config tab has a `gateway (add)` row and a row for each field (see [the control panel](control-panel.md#gateways)). That writes a `[gateway.<name>]` to your `~/.config/afk/config.toml`, which you can also do by hand: a `[gateway.<name>]` with `url` and `key = "env:NAME"` (or, while config.toml doesn't exist, in `~/.config/afk/router.json` as `litellm_base_url`). A project's `.afk/config.json` can never set it: the gateway receives your gateway key, so a repository you clone can't choose where it goes. See [configuration](../reference/configuration.md#gatewayname).

On the route card a gateway route is named after its `[gateway.<name>]` (an environment gateway is just "gateway"), and the headroom column says what serves it and where when the gateway sets `engine` and `host`, for example `[vLLM] vLLM · factory`:

```toml
[gateway.agentgateway]
kind = "agentgateway"
url = "https://gateway.lan:4000"
key = "env:AGENTGATEWAY_KEY"
engine = "vllm"
host = "factory"
```

AFK asks the gateway for its model list (`GET /v1/models`) when routing. A gateway model is a candidate only while the gateway answers and lists it; the built-in catalog includes one local coding model (`qwen36-27b`) as an example. Gateway models count as free and get a bonus on low-risk coding and research.

### How a gateway route is launched

Gateway routes run on `claude` only, so that AFK can keep your Claude plan login out of the request:

- `ANTHROPIC_BASE_URL` is set to the gateway.
- `ANTHROPIC_AUTH_TOKEN` is copied, at launch, from the gateway key variable. The key is never printed or written to a launch plan; the plan only names the variable.
- `CLAUDE_CONFIG_DIR` points at a separate directory (`~/.local/state/agent-flow-kit/gateway-claude`), so your plan login isn't loaded.
- Every other Claude and Anthropic variable in your environment is unset for that process.

The key goes only to an address you configured: a `[gateway.<name>]` `url`, or the one from `AFK_LITELLM_BASE_URL` (or the older `router.json`). A route that names any other address, such as a route saved before you changed the gateway, is refused with the addresses you do have, whichever variable holds the key, `AFK_GATEWAY_KEY_ENV` included. Route again and it launches.

A gateway on plain `http://` to what looks like a public host gets a warning each time AFK loads your settings, because the key and your prompts cross the network unencrypted. It still launches. Loopback and private addresses (10.x, 172.16-31.x, 192.168.x, 100.64.x), single-label names, and names under `.local`, `.lan`, `.home`, `.internal`, `.home.arpa`, `.ts.net`, `.svc`, `.cluster.local`, `.localhost` or `.test` don't warn.

The key variable must be a plain name that is not a vendor credential (`CLAUDE_*`, `ANTHROPIC_*`, `OPENAI_*`, `CODEX_*`, `XAI_*`, `GROK_*`, `GEMINI_*`, `GOOGLE_*`, `OPENCODE_*`), so AFK never picks up a plan token from a vendor's own variables by mistake. It checks the variable's name, not where its value came from: put only a key your gateway issued in it, never a copy of a plan login. With no gateway URL or no key, the route isn't launched and AFK says what to set.

A plan is never sent through a gateway, even on its own CLI.

The gateway key variables themselves are removed from the environment of every CLI AFK starts, gateway route or not, so the agent's shell commands can't read them. If you run `afk` from inside a CLI session and want gateway routes there, set `AFK_KEEP_SECRETS=1`.

## Planned: any gateway, any number of them

AFK is meant to work with whichever gateway you use. The plan:

- **Gateways in config**, as many as you like, each with a name, a preset or `custom`, the base URL, the API style it speaks (OpenAI-compatible, Anthropic Messages, or both), where its key comes from (an environment variable, the OS keychain or 1Password), where to list its models, its cost class, and optional model and benchmark mappings.
- **Presets** for the popular gateways: LiteLLM, OpenRouter, Portkey, Cloudflare AI Gateway, Vercel AI Gateway, Kong AI Gateway, Envoy AI Gateway, agentgateway, Helicone, Bifrost, and local OpenAI-compatible servers (Ollama, vLLM, LM Studio, llama.cpp).
- **Commands**: `afk gateway add | list | test | models | remove`.
- **More CLIs**: a gateway model runs on any CLI that speaks the gateway's API (Claude Code for Anthropic-style gateways, Codex and OpenCode for OpenAI-compatible ones, and others where their CLI allows a custom endpoint), each launch with its own config and the gateway's key only.
- **One pool per gateway**, with its own health check.

`AFK_LITELLM_BASE_URL` and `AFK_GATEWAY_KEY` will keep working as a gateway named `default`.
