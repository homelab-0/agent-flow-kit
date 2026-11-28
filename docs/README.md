# AFK documentation

AFK runs the best agent CLI on your machine for the task in front of you. These pages cover what AFK does today, how to use it, and the exact formats it reads and writes.

Anything not built yet is marked **Planned** and listed in the [roadmap](../README.md#roadmap).

## Getting started

- [Install](getting-started/install.md): build from source; packaged installs are planned
- [Quick start](getting-started/quickstart.md): your first routed session in five minutes

## Guides

- [The route card](guides/route-card.md): the interactive session, the keys, the Why panel, the receipt
- [The control panel](guides/control-panel.md): the Harnesses, Benchmarks, Skills, MCP, Runs and Config tabs, and `afk status`
- [Skills](guides/skills.md): one copy of every skill, synced into each CLI, with drift you decide on
- [MCP servers](guides/mcp.md): one list of MCP servers, written into each CLI in its own format, with a tools/list test
- [How routing works](guides/routing.md): task kinds, scoring, the rules no route can break, effort
- [Agent CLIs (harnesses)](guides/harnesses.md): which CLIs AFK supports and what `afk harness` shows
- [Subscription pools](guides/pools.md): how AFK knows how much of each plan is left
- [Local models](guides/local-models.md): Ollama, LM Studio, llama.cpp, vLLM, SGLang, KoboldCpp, Docker Model Runner and other engines on this machine, found and routed to
- [Model gateways](guides/gateways.md): routing to a LiteLLM-style gateway without exposing a plan login
- [Permission modes](guides/permissions.md): read-only, ask, edits, auto and yolo, per CLI, and `afk trust`
- [One-shot answers (`-p`)](guides/print-mode.md): headless runs with failover
- [AFK as an API](guides/serve.md): `afk serve` and API keys, so a gateway can route through AFK or use one CLI's subscription
- [Run records and receipts](guides/runs.md): what is saved after each session
- [Scripting AFK](guides/scripting.md): `--explain --json` and `--launch-plan` for scripts and front ends

## Reference

- [Command line](reference/cli.md): every command, option and exit code
- [Configuration](reference/configuration.md): files, project settings and environment variables
- [JSON formats](reference/json.md): explain, route, launch plan, harnesses, pools and run records
- [Harness manifests](reference/harness-manifests.md): how each CLI is described, and overriding one
- [Benchmark catalog](reference/benchmark-catalog.md): the format the router scores from, and `afk bench sync`

## More

- [Security and privacy](security.md): what AFK reads, what it never stores, and the login rules
- [Development](development.md): architecture, tests and the parity fixtures
