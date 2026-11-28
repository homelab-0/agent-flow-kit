# AFK as an API: `afk serve` and API keys

`afk serve` turns AFK into a model API. A gateway such as LiteLLM, or any client that speaks the OpenAI or Anthropic format, calls it with an AFK key. AFK answers by running one of your agent CLIs headless and sending back what it said.

There are two kinds of key:

- A **router key** lets AFK decide. The caller asks for the model `afk/auto` and AFK picks the CLI and model from the benchmarks and what each plan has left, the same way `afk -p` does.
- A **harness key** is tied to one CLI. The caller asks for `grok/<model>` (or `claude/<model>`, `codex/<model>`, and so on) and AFK runs exactly that. It makes no routing decision.

So a gateway can treat AFK as one smart provider, or take each of your subscriptions as its own provider with its own key and limits.

## Quick start

```sh
afk keys add gateway                 # a router key; the key is printed once
afk keys add my-grok --harness grok  # a key for the Grok CLI only
afk config set serve.plan_runs true  # let your CLIs' own sign-ins answer (see below)
afk serve                            # http://127.0.0.1:8484 until ctrl+c
```

Try it:

```sh
curl http://127.0.0.1:8484/v1/chat/completions \
  -H "Authorization: Bearer $AFK_KEY" \
  -d '{"model":"afk/auto","messages":[{"role":"user","content":"What does a mutex do?"}]}'
```

## Adding AFK to a gateway

AFK is an ordinary OpenAI-compatible provider: a base URL ending in `/v1`, an API key, a model name. In LiteLLM's `config.yaml`:

```yaml
model_list:
  - model_name: afk-auto
    litellm_params:
      model: openai/afk/auto            # the part after openai/ is sent to AFK
      api_base: http://afk-host:8484/v1
      api_key: os.environ/AFK_ROUTER_KEY
  - model_name: grok-subscription
    litellm_params:
      model: openai/grok/grok-5         # a model your Grok CLI lists
      api_base: http://afk-host:8484/v1
      api_key: os.environ/AFK_GROK_KEY
```

The Anthropic format works the same way through `/v1/messages`, with the key in `x-api-key`. Any other gateway or client that can point at a custom OpenAI or Anthropic endpoint works too; nothing here is specific to LiteLLM.

When the gateway runs on another machine, AFK has to listen beyond this one:

```sh
afk config set serve.listen 0.0.0.0:8484
```

The API is plain HTTP. On a network you don't control, keep it on a private network (Tailscale, a VPN) or put a TLS reverse proxy in front, because keys and prompts travel in the clear. `afk serve` says so when it starts on such an address.

## Model names

| Key | Model | What runs |
|---|---|---|
| router | `afk/auto` | AFK guesses the kind of task from the prompt and routes it |
| router | `afk/coding`, `afk/quick`, `afk/complex`, `afk/review`, `afk/architecture`, `afk/webdev`, `afk/research`, `afk/security` | routed as that [kind of task](routing.md) |
| harness | `<cli>/<model>`, or just `<model>` | that model on the key's CLI |
| harness | `<cli>/default` | the CLI's own default model, when it reports one |

`GET /v1/models` lists what the key can ask for. For a harness key that is the list the CLI itself reported for your account, never a catalog's guess. When a CLI reports a list, a model outside it is refused with 404; when it reports none, the name is passed to the CLI as given.

`reasoning_effort` (OpenAI) and `output_config.effort` (Anthropic) set the CLI's effort: `low`, `medium` or `high`.

## How a chat request becomes a CLI run

A gateway sends a list of chat messages. An agent CLI takes one prompt. AFK's translation layer sits between them:

1. **Messages become one prompt.** A single user message is passed as it is. A longer conversation is laid out with the system instructions first, then the earlier turns in order, then the message to answer. Every call is a new CLI session; the caller sends the whole conversation each time, as the chat APIs expect, and AFK keeps none of it.
2. **The CLI runs headless**, the way [`afk -p`](print-mode.md) runs it, with the same failover for a router key. A harness key never fails over: its failure is reported.
3. **The answer goes back in the caller's format**: a chat completion or an Anthropic message, whole or as a server-sent stream.

Some things a chat API offers have no equivalent in a CLI run, and AFK is explicit about each:

- **Text only.** A message with an image, audio or a file is refused with 400. It is not dropped and answered as if it had been seen.
- **Your tools are not passed on.** The CLI is an agent with tools of its own. A request that lists `tools` is answered in plain text; one that forces a tool call (`tool_choice` other than `auto` or `none`) is refused with 400.
- **Sampling settings are ignored**: `temperature`, `top_p`, `max_tokens`, `stop` and the like. The response's `X-AFK-Ignored` header names the ones the request carried.
- **Token usage is the CLI's own count or nothing.** Claude Code and Codex report tokens, and AFK passes them on (they cover the whole run, the CLI's own system prompt included). For a CLI that reports none, an OpenAI response has no `usage`; an Anthropic response, where the field is required, carries zeros and the header `X-AFK-Usage: not-reported`. AFK never estimates.
- **A prompt is at most 120 KiB.** It reaches the CLI as one command argument, and that is what the operating system allows. A longer conversation gets 413.

### Streaming

With `"stream": true` the answer is sent as it is written, for the CLIs that print it that way:

| CLI | Streams |
|---|---|
| Claude Code | word by word |
| Codex | one message at a time |
| others | the whole answer in one piece when the run ends |

While a run is working and has nothing to say yet, AFK sends a keep-alive every 15 seconds, so a gateway doesn't take the silence for a dead connection. For long tasks, prefer streaming: a non-streamed call is one HTTP request that stays open until the run ends, and most gateways give up on those after a few minutes.

The stream opens with the first text or the first keep-alive, not before. A call that fails earlier than that (a model the key can't ask for, a plan out of quota) still gets its own HTTP status, so a gateway can move on to its next provider.

If a run fails after part of its answer was already streamed, the stream ends with an error event. AFK does not fail over at that point, because the caller has already read text from the first route.

Every response says which CLI and model answered: the `X-AFK-Route` and `X-AFK-Run` headers, and an `afk` object beside the standard fields (`{"harness": "claude", "model": "sonnet", "run": "r-1c04"}`).

## What a call may do

By default a call can only answer. Its run is in [read-only mode](permissions.md), in a new empty folder that is deleted when the run ends, and outside a trusted repository, so the CLI loads none of a project's hooks or settings. It cannot see or change your files.

If you want a key whose calls do real agent work, give that key one folder and a mode:

```sh
afk keys add builder --harness codex --dir ~/work/app --mode auto
```

Calls through `builder` then run in `~/work/app` in `auto`. The modes are `read-only`, `edits`, `auto` and `yolo`; `ask` is left out because nobody is there to answer, and `yolo` needs the folder to be [trusted](permissions.md#yolo-stays-deliberate) as it does everywhere else. Anyone who holds that key can change that folder, so treat it accordingly.

## Using your subscriptions

A CLI signed in to a subscription answers API calls only when you say so:

```sh
afk config set serve.plan_runs true
```

The same switch is on the control panel's Config tab (`serve.plan_runs`), next to `serve.listen`.

While it is off (the default), a call can be answered only by a [gateway](gateways.md), a [local engine](local-models.md) or a free pool, and a harness key's call is refused with 403 and a message that names this setting. The switch takes effect at once, without restarting `afk serve`.

It is off by default because it changes what your sign-ins are used for. Each vendor's terms decide what its plan sign-in may do, and they differ. AFK doesn't check them and doesn't stop you: it tells you, starts you with careful limits, and leaves the choice with you. What most often gets an account limited or closed:

- several people sharing one subscription
- traffic no single person would produce: around the clock, or many runs at once
- reselling access, or putting the sign-in behind a public service

Making a harness key prints the same warning.

## Limits

Every key starts with limits, so a script in a loop or a busy gateway can't drain a plan or look like abuse by accident:

| | requests a minute | requests a day | runs at once |
|---|---|---|---|
| router key | 10 | 500 | 2 |
| harness key | 6 | 200 | 1 |

They are yours to change, one by one, or to turn off:

```sh
afk keys set my-grok --per-minute 20 --per-day 0   # 0 turns a limit off
afk keys set my-grok --no-limits
```

A call over a limit gets HTTP 429 with `Retry-After`, in the caller's error format. A gateway treats that like any provider's rate limit and moves on to its next one, which is what makes AFK safe to put in a rotation. A change applies to the next call. The counts live in the running `afk serve`; after a restart the day's count is rebuilt from the [run records](runs.md).

A CLI's own limit shows up the same way: when the run fails because the plan is out of quota or needs a sign-in, the call gets 429, and the router sets that pool aside as it does for `afk -p`.

## Keys

```sh
afk keys                      # every key, what it reaches, its limits
afk keys add <name> [--harness <cli>] [--models a,b] [limits] [--dir <folder> --mode <mode>]
afk keys set <name> ...       # change limits, models or folder
afk keys rotate <name>        # a new secret; the old one stops at once
afk keys revoke <name>        # stop it working, keep the record
afk keys rm <name>            # delete it
```

A key looks like `afk_3401a228_…`: the eight characters after `afk_` are its public id, which is what logs and `afk keys` show. The rest is the secret. AFK shows it once, when the key is made or rotated, and stores only a SHA-256 hash, in `~/.local/state/afk/keys.json` (mode 600). Nobody, AFK included, can read a key back; rotate it if you lose it.

`--models` narrows a harness key to the models you list.

## Running it

```sh
afk serve [--listen host:port]   # in the foreground
afk serve status                 # is it running, and where
afk serve stop
```

`afk serve` logs one line per call to stderr: the key's name, the model asked for, the route that answered, the status and the time. It never logs a prompt or an answer. Each call that ran is also a [run record](runs.md) with `where: "serve"` and the key's name.

A run is stopped when its caller hangs up, when `afk serve` stops, or after 30 minutes.

## Status codes

| Status | When |
|---|---|
| 400 | the request can't be run: no text, an image, a forced tool call, an unknown role |
| 401 | no key, or one that is revoked, rotated or mistyped |
| 403 | the call needs a CLI's own sign-in and `serve.plan_runs` is off |
| 404 | a model the key can't ask for, or one the CLI refused |
| 413 | the request or its prompt is too large |
| 429 | a limit of the key, or of the plan behind it |
| 502 | the CLI ran and failed; the message carries the start of its error |
| 503 | nothing here can answer: the CLI isn't installed, or no route is usable right now |
| 504 | the run passed 30 minutes and was stopped |

## Not there yet

- The OpenAI Responses API (`/v1/responses`) and embeddings.
- Passing the caller's tools through to the model.
- Prompts above 120 KiB.
- TLS in `afk serve` itself (`serve.tls` is reserved).
- A key that reaches one provider across several CLIs.
