# Local models

AFK finds the inference engines running on this machine and routes to their models like any other route. A local model runs in Claude Code pointed at the engine, from a config directory of its own, so no plan login is used and nothing leaves this PC.

## What AFK looks for

Each time it routes, AFK asks these addresses on this machine what they serve:

| Port | Usually |
|---|---|
| 11434 | Ollama |
| 1234 | LM Studio |
| 8080 | llama.cpp (`llama-server`, also inside llamafile and Jan), LocalAI, MLX, Strata |
| 8000 | vLLM |
| 30000 | SGLang |
| 5000 | TabbyAPI |
| 5001 | KoboldCpp |
| 9997 | Xinference |
| 12434 | Docker Model Runner |
| 13305 | Lemonade |
| 23333 | LMDeploy |

It works out which engine answers (from Ollama's own API, the `owned_by` of the models an OpenAI-compatible server lists, or the endpoints only one engine has) and keeps the models that can run Claude Code:

- The engine must have the Anthropic Messages API (`/v1/messages`). AFK checks with an empty request, which such an engine refuses as malformed and any other answers with "not found"; nothing is generated. Ollama has it from 0.14, llama.cpp's `llama-server`, vLLM and LM Studio in their current releases, and KoboldCpp, Xinference, Docker Model Runner and Lemonade have it too. An engine without it (Strata, TabbyAPI and LMDeploy today) gets no routes. It still shows on the Usage tab's Engines view as "no API · needs a gateway": put a gateway that speaks the Messages API in front of it and add that [gateway](gateways.md).
- Ollama says which models can call tools, and only those are kept (Claude Code needs tools). LM Studio says which models are embeddings, and those are left out. On other engines, models whose names say embedding, reranker, speech or TTS are left out.

An engine on another port goes in `local.urls`. Only addresses on this machine are probed (`localhost`, `127.0.0.1`, `::1`); an engine on another machine is a [gateway](gateways.md).

```toml
[local]
engines = "auto"                          # "off": only the urls below
urls = ["http://127.0.0.1:9000"]          # more engines on this machine
gpu = "RTX 5090"                          # label for the route card
```

`AFK_LOCAL_ENGINES=off` turns the search off for one run.

## How they are scored

A model the [benchmark catalog](../reference/benchmark-catalog.md) knows by its open-weights name takes the catalog's scores: `qwen3.6:27b` (Ollama), `Qwen/Qwen3.6-27B` (vLLM) and `qwen3.6-27b-instruct-q4_k_m.gguf` (llama.cpp) are all the catalog's Qwen3.6 27B. Any other model gets a flat estimate of 45, below every plan model, so it is picked only when you ask for it or `prefer = "cheap"` leans that way. The rules in [routing](routing.md) apply as they do to a free gateway model: low-risk work leans toward them, and reviews never go to one unless you allow free reviewers.

Local models have no effort setting, so the card shows `—` and `tab` does nothing on their row.

## On the route card

Each engine found is a row of its own, beside the CLIs on their plans, named after the engine with its logo, and the headroom column says where it runs:

```
   OL ollama       qwen36-14b       —      51.0   OL this PC · 5090 free
```

The box for a local route says `Ollama on localhost · nothing leaves this PC` and `runs on  Ollama on this PC (RTX 5090) · idle`. The GPU is the first one `nvidia-smi` lists, or `local.gpu`; without either the card says `this PC`. Ollama says whether a model is loaded (`idle` or `loaded`); other engines show `state n/e`.

## How it launches

```
ANTHROPIC_BASE_URL=http://127.0.0.1:11434
ANTHROPIC_AUTH_TOKEN=local                 # a placeholder; local engines need no key
CLAUDE_CONFIG_DIR=~/.local/state/agent-flow-kit/local-claude
ANTHROPIC_MODEL, ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL, CLAUDE_CODE_SUBAGENT_MODEL = the model
claude --model <model>
```

Every other Claude and Anthropic variable is unset, as for a gateway route, so your plan login can't reach the engine. Every model Claude Code would ask for (its fast model, subagents) is the local one, because the engine has no other. A local route that names an address off this machine is refused.

An engine started with an API key of its own (vLLM's `--api-key`, for example) is best set up as a [gateway](gateways.md), where AFK sends the key.
