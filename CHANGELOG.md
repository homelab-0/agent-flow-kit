# Changelog

## [0.4.0](https://github.com/homelab-0/agent-flow-kit/compare/v0.3.0...v0.4.0) (2026-11-28)


### Features

* **harness:** ask each CLI for its plan, models and usage ([#200](https://github.com/homelab-0/agent-flow-kit/issues/200)) ([3a3593f](https://github.com/homelab-0/agent-flow-kit/commit/3a3593fd4e64f0b419a1f8d85d223bc70c02d39b))
* **harness:** read usage for Antigravity, and for Claude and Grok on opt-in ([#203](https://github.com/homelab-0/agent-flow-kit/issues/203)) ([632200d](https://github.com/homelab-0/agent-flow-kit/commit/632200d8ad9a38c83d7612c20aa881904ee142c2))
* **tui:** reopen the last run's session in its CLI with /open ([#201](https://github.com/homelab-0/agent-flow-kit/issues/201)) ([d78faa9](https://github.com/homelab-0/agent-flow-kit/commit/d78faa9184cb8ee815e0142727ba219b208c9f61))

## [0.3.0](https://github.com/homelab-0/agent-flow-kit/compare/v0.2.0...v0.3.0) (2026-11-28)


### Features

* **tui:** add an MCP server or a skill from its tab ([#194](https://github.com/homelab-0/agent-flow-kit/issues/194)) ([02ed6cc](https://github.com/homelab-0/agent-flow-kit/commit/02ed6cc2cabab4720069e7605241f2b9545f5069))
* **tui:** add, change and remove gateways from the Config tab ([b9308db](https://github.com/homelab-0/agent-flow-kit/commit/b9308dbd9a4e4d623313eac36dbd2ce6649545b9))
* **tui:** change settings from the Config tab ([31a0633](https://github.com/homelab-0/agent-flow-kit/commit/31a0633b00f8982cad711c47a08aab790425e90c))
* **tui:** run a task inside AFK and show the answer ([0ca685f](https://github.com/homelab-0/agent-flow-kit/commit/0ca685f41de161f1dab6d5a6598fe5366166a7df))
* **tui:** say how old a reported usage figure is ([8abe09a](https://github.com/homelab-0/agent-flow-kit/commit/8abe09a6ad28349a64145417b4f66e2d541f514c))
* **tui:** stay in AFK after a CLI session ends ([48bc87e](https://github.com/homelab-0/agent-flow-kit/commit/48bc87ea2f4235b38e0bc892364e481872b22ffe))


### Fixes

* **harness:** take sign-in state from each CLI's own status command ([f242306](https://github.com/homelab-0/agent-flow-kit/commit/f2423069f7901991c4af125a13a1eb38bc5850f3))
* **router:** show plan usage only when the CLI reported it ([4d1ee8d](https://github.com/homelab-0/agent-flow-kit/commit/4d1ee8dde2a67aded44e245718456eb4f77e9130))
* **router:** stop guessing plan tiers and drop homelab wording from the catalog ([57cf6aa](https://github.com/homelab-0/agent-flow-kit/commit/57cf6aaa9433b7939c30fbe54a3826f30f9d8435))
