# AFK documentation

AFK runs the best agent CLI on your machine for the task in front of you. These pages cover what AFK does today, how to use it, and the exact formats it reads and writes.

Anything not built yet is marked **Planned** and listed in the [roadmap](../README.md#roadmap).

## Getting started

- [Install](getting-started/install.md): build from source; packaged installs are planned
- [Quick start](getting-started/quickstart.md): your first routed session in five minutes

## Guides

- [The route card](guides/route-card.md): the interactive session, the keys, the Why panel, the receipt
- [How routing works](guides/routing.md): task kinds, scoring, the rules no route can break, effort
- [Agent CLIs (harnesses)](guides/harnesses.md): which CLIs AFK supports and what `afk harness` shows
- [Subscription pools](guides/pools.md): how AFK knows how much of each plan is left
- [Model gateways](guides/gateways.md): routing to a LiteLLM-style gateway without exposing a plan login
- [Permissions](guides/permissions.md): asking versus yolo, and what is planned
- [One-shot answers (`-p`)](guides/print-mode.md): headless runs with failover
- [Run records and receipts](guides/runs.md): what is saved after each session
- [Scripting AFK](guides/scripting.md): `--explain --json` and `--launch-plan` for scripts and front ends

## Reference

- [Command line](reference/cli.md): every command, option and exit code
- [Configuration](reference/configuration.md): files, project settings and environment variables
- [JSON formats](reference/json.md): explain, route, launch plan, harnesses, pools and run records
- [Benchmark catalog](reference/benchmark-catalog.md): the format the router scores from

## More

- [Security and privacy](security.md): what AFK reads, what it never stores, and the login rules
- [Development](development.md): architecture, tests and the parity fixtures

## Legacy

AFK grew out of a BMAD/Orca lifecycle kit and a Paperclip-driven factory. That code is still in the repository while it is retired; its documents are kept for reference: [legacy README](LEGACY-README.md), [factory](FACTORY.md), [lifecycle contract](LIFECYCLE-CONTRACT.md), [Paperclip](PAPERCLIP.md), [release update](RELEASE-UPDATE.md), [runtime experience](RUNTIME-EXPERIENCE.md). None of it is needed to use `afk`.
