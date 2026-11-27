# MCP servers

AFK keeps one list of MCP servers and writes each into every agent CLI you have installed, in that CLI's own format. Add a server once, run `afk mcp sync`, and Claude Code, Codex, OpenCode, Gemini CLI and Copilot CLI all have it.

## The list: `mcp.toml`

`~/.config/afk/mcp.toml` (`afk mcp edit` opens it, with a commented template the first time):

```toml
[[server]]
name = "github"
url = "https://api.githubcopilot.com/mcp/"
bearer = "env:GITHUB_MCP_TOKEN"     # the variable that holds the token

[[server]]
name = "tools"
via = "homelab"                     # a [gateway.homelab] in config.toml

[[server]]
name = "playwright"
command = ["npx", "@playwright/mcp@latest"]
env = ["PLAYWRIGHT_BROWSERS_PATH"]  # passed through by name
harnesses = ["claude", "codex"]     # default: all
```

| Key | Meaning |
|---|---|
| `name` | lowercase letters, digits, `-` and `_`; the entry's name in every CLI |
| `url` | an HTTP (streamable) server |
| `command` | a stdio server: the program and its arguments |
| `via` | `http`, `stdio`, or a gateway's name in `config.toml`. Through a gateway, the server's URL is the gateway's MCP endpoint (`mcp = "..."` in `[gateway.<name>]`, default `/mcp` on the gateway's host); `path = "/mcp/github"` picks another path on that host |
| `bearer` | `env:NAME`: the variable holding an HTTP server's token |
| `env` | names of variables a stdio server needs |
| `harnesses` | `"all"` (the default) or a list of CLI names |
| `[defaults] via` | the `via` for servers that set neither `url`, `command` nor `via` |

**Tokens never pass through AFK.** `mcp.toml` holds variable names, never values. Each CLI is told to read the variable in its own syntax: `${NAME}` for Claude Code, `bearer_token_env_var` and `env_vars` for Codex, `{env:NAME}` for OpenCode and `$NAME` for Gemini CLI. AFK doesn't know such a syntax for Copilot CLI, so a server with a token or `env` shows as not supported there (`–`) rather than being written with a secret.

## Where each CLI's entry goes

| CLI | File | Format |
|---|---|---|
| Claude Code | `$CLAUDE_CONFIG_DIR/.claude.json`, else `~/.claude.json` (user scope) | `mcpServers` |
| Codex | `$CODEX_HOME/config.toml`, else `~/.codex/config.toml` | `[mcp_servers.<name>]` in a marked section |
| OpenCode | `~/.config/opencode/opencode.json` | `mcp` |
| Gemini CLI | `~/.gemini/settings.json` | `mcpServers` |
| Copilot CLI | `~/.copilot/mcp-config.json` | `mcpServers` |
| Grok CLI, Antigravity, pi | not supported (`–`) | |

Claude Code's format was checked with `claude mcp add` and `claude mcp get` (2.1.332). The others come from each CLI's documentation; if yours differs, [override its manifest](../reference/harness-manifests.md#mcp).

JSON files keep every other key, in order; only the servers object changes. Codex's `config.toml` is never rewritten: AFK's servers live in one section between two marker comments at the end, and only that section changes, so your comments and layout stay. A symlinked config file (dotfiles) stays a symlink.

## Commands

```text
afk mcp [status] [--json]             each server in each CLI; changes nothing
afk mcp sync [--dry-run] [--json]     write new and changed servers into the CLIs
afk mcp test <server> [--json]        connect and list its tools (tools/list)
afk mcp keep <server> <cli>           leave a CLI's edited entry as its own
afk mcp restore <server> <cli>        write AFK's entry back over a CLI's edit
afk mcp enable|disable <server> <cli> turn a server on or off for one CLI
afk mcp edit                          open mcp.toml in your editor
afk mcp path                          print where mcp.toml is
```

`test` reads the token from its variable and sends it only to that server. Its result (up or down, how many tools) is kept for the MCP tab.

## What a sync will and won't do

- It **adds** a server to each CLI it's for, and **updates** an entry AFK wrote when `mcp.toml` changed.
- It **removes** AFK's entry when the server left `mcp.toml` or was turned off for that CLI.
- It **adopts** an identical entry you added by hand (except in Codex, where AFK only manages its own section).
- It **never touches an entry of your own** with the same name (a conflict, `!`).
- It **never overwrites an edit made in a CLI** (drift, `↻`): `restore` writes AFK's entry back, and `keep` leaves the edited one as yours (AFK stops managing it).
- It leaves a file it can't parse alone (`?`), and says why.

Every change runs under a lock. A file is backed up under `~/.config/afk/state/backups/mcp/<time>/<cli>/` first, written beside the old one and renamed into place, then read back to check each entry. If anything fails, every file already written is put back. AFK records what it wrote in `~/.config/afk/state/mcp.json`.

A CLI that is running may rewrite its own config (Claude Code does). Sync while the CLIs are idle; if a CLI overwrote AFK's entry, the next status shows it as drift.

## The MCP tab

Press `5` in the [control panel](control-panel.md) (or `/mcp` in the composer): one row per server with how it's reached, its tool count and status from the last test, and a column per CLI with the same marks as the [Skills tab](skills.md#the-skills-tab), plus `?` for a file AFK can't read.

`↑` `↓` pick a server and `←` `→` a CLI. `space` turns it on or off for that CLI, `s` syncs, `t` tests the server, `↵` connects and lists its tools with their descriptions (`↑` `↓` scroll, `esc` goes back; it counts as a test), and `a` opens `mcp.toml`. When an entry has drifted, a box names it: `k` keeps the CLI's entry and `c` restores AFK's.

**Not yet:** project-scope servers (`.mcp.json`).
