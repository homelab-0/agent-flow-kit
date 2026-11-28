# Changelog

## [0.5.0](https://github.com/homelab-0/agent-flow-kit/compare/v0.4.0...v0.5.0) (2026-11-28)


### Features

* add afk update, Config switches, and the OpenCode and Pi logos ([#204](https://github.com/homelab-0/agent-flow-kit/issues/204)) ([75f6195](https://github.com/homelab-0/agent-flow-kit/commit/75f6195cc2f7c78efc48bade490526f48724758d))
* **bench:** blend SWE-bench, Aider and your own leaderboards into scores ([#213](https://github.com/homelab-0/agent-flow-kit/issues/213)) ([f4ed469](https://github.com/homelab-0/agent-flow-kit/commit/f4ed4691052a529a518b7dfa841b0ec2b90f9bbd))
* **harness:** say when a plan has no 5-hour limit, and add afk harness scan ([#207](https://github.com/homelab-0/agent-flow-kit/issues/207)) ([0a0dd84](https://github.com/homelab-0/agent-flow-kit/commit/0a0dd8494b624bc71fa1e690b3ace248b73a433b))
* **local:** find KoboldCpp, Xinference, LMDeploy, TabbyAPI, Docker Model Runner, Lemonade and Strata ([#215](https://github.com/homelab-0/agent-flow-kit/issues/215)) ([a912ca7](https://github.com/homelab-0/agent-flow-kit/commit/a912ca7440a67322fb0226c60829f10d4c035170))
* **mcp:** import servers from your CLIs and redesign the MCP tab ([#211](https://github.com/homelab-0/agent-flow-kit/issues/211)) ([c5967f6](https://github.com/homelab-0/agent-flow-kit/commit/c5967f64fcaf2e63ad8d6b2946afa26b69425e91))
* **serve:** API keys and afk serve, so a gateway can route through AFK ([#218](https://github.com/homelab-0/agent-flow-kit/issues/218)) ([396c237](https://github.com/homelab-0/agent-flow-kit/commit/396c2371c47effac2763e8108c2d072df9c67b24))
* **tui:** API tab for keys and afk serve, and afk serve start ([#219](https://github.com/homelab-0/agent-flow-kit/issues/219)) ([9eb7be5](https://github.com/homelab-0/agent-flow-kit/commit/9eb7be52dec8967de594d9c8ae3433a9e0f5e95a))
* **tui:** call the Usage engines view Gateways & local models ([#217](https://github.com/homelab-0/agent-flow-kit/issues/217)) ([446fba8](https://github.com/homelab-0/agent-flow-kit/commit/446fba8fcfc22549e92c960d1374ab403c9eba94))
* **tui:** logos for every gateway kind and local engine ([#214](https://github.com/homelab-0/agent-flow-kit/issues/214)) ([40ce5b6](https://github.com/homelab-0/agent-flow-kit/commit/40ce5b621bf77326a01d39f8b0bbbd5c7b77a9f1))
* **tui:** redesign the Harnesses tab with discovery and every logo ([#208](https://github.com/homelab-0/agent-flow-kit/issues/208)) ([34b86dd](https://github.com/homelab-0/agent-flow-kit/commit/34b86dd23de9c3ff671a72caac24c3a6d557dbc0))
* **tui:** redesign the Skills tab with a scope column and a detail box ([#209](https://github.com/homelab-0/agent-flow-kit/issues/209)) ([b1f8ef9](https://github.com/homelab-0/agent-flow-kit/commit/b1f8ef9de1ccdd63f0fba56920a47206912062be))
* **tui:** show the tabs everywhere, add a command menu and palette, update every CLI from AFK ([#206](https://github.com/homelab-0/agent-flow-kit/issues/206)) ([e082a32](https://github.com/homelab-0/agent-flow-kit/commit/e082a329b234a2930601ef81180f8572d8958d07))
* **tui:** split Benchmarks into leaderboard, sources and why AFK picks ([#212](https://github.com/homelab-0/agent-flow-kit/issues/212)) ([6899192](https://github.com/homelab-0/agent-flow-kit/commit/6899192637086013fc5714190015425c1611ad83))
* **tui:** turn the Runs tab into Usage with plan cards and run history ([#210](https://github.com/homelab-0/agent-flow-kit/issues/210)) ([7b06fa3](https://github.com/homelab-0/agent-flow-kit/commit/7b06fa393ba57025d8debb7050ad708d42eab5ca))


### Fixes

* **local:** Strata is a normal engine with its own logo ([#216](https://github.com/homelab-0/agent-flow-kit/issues/216)) ([3cb4a94](https://github.com/homelab-0/agent-flow-kit/commit/3cb4a948e853776d4d7f0afac5dbaa6d0b1738b0))
* **serve:** report a refused request in seconds, and keep --dry-run from running -p ([#220](https://github.com/homelab-0/agent-flow-kit/issues/220)) ([120c49c](https://github.com/homelab-0/agent-flow-kit/commit/120c49ce1e32bbd5acb856ded25eef914a552c2a))

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
