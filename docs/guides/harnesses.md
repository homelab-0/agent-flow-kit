# Agent CLIs (harnesses)

AFK doesn't run models itself. It picks one of the agent CLIs you already have, and hands it the task.

## Supported CLIs

| CLI | Command | Found by `afk harness` | Routed and launched |
|---|---|:---:|:---:|
| Claude Code | `claude` | yes | yes |
| Codex CLI | `codex` | yes | yes |
| OpenCode | `opencode` | yes | yes |
| Grok CLI | `grok` | yes | yes |
| Antigravity CLI | `agy` | yes | yes |
| Gemini CLI | `gemini` | yes | planned |
| GitHub Copilot CLI | `copilot` | yes | planned |
| Cursor Agent | `cursor-agent` | yes | planned |
| Kiro CLI | `kiro-cli` | yes | planned |
| Qwen Code | `qwen` | yes | planned |
| Kimi Code | `kimi` | yes | planned |
| Pi | `pi` | yes | yes |
| Devin CLI | `devin` | yes | planned |

## `afk harness`

```sh
afk harness           # the CLIs installed here
afk harness --all     # every supported CLI, installed or not
afk harness --json    # machine-readable (schema afk-harnesses/3)
```

For each installed CLI it shows:

- **Version**, from `<cli> --version`. All CLIs are asked at once, five seconds each at most, so one that hangs can't stall the rest. A CLI that fails or hangs is reported as unhealthy with the first line of its error.
- **Sign-in**: whether the CLI looks signed in.
- **Installed with**: mise, npm, bun, pnpm, Homebrew, uv, pipx, cargo or self-managed, and the package name.
- **Effort**: the effort levels it accepts.
- **Update with**: the command that updates it. For a mise shim, which doesn't say which tool backs it, AFK says "via mise" instead of suggesting `mise upgrade`, which would upgrade everything.

It changes nothing: `afk harness` only reads.

### Where AFK looks

On your `PATH` first, then the usual install folders (`~/.local/bin`, `~/.bun/bin`, `~/.cargo/bin`, `~/.npm-global/bin`, the mise shims, and the Grok and OpenCode installers' own folders), then `/opt/homebrew/bin`, `/usr/local/bin` and Linuxbrew. Set `AFK_HARNESS_BIN_DIR` to make one folder the only place AFK looks; that is useful in containers and tests.

### Sign-in states

| State | Means |
|---|---|
| `authenticated` | the CLI's own login file exists and is not empty |
| `signed_out` | the login file is missing or empty; AFK shows the command to sign in |
| `unknown` | AFK can't tell: the CLI has no reliable on-disk check, the file can't be checked, or the login is in the macOS Keychain |
| `not_installed` | the CLI isn't here |

The check only looks at whether the login file is there. AFK never opens it, so it never reads, prints or stores a token, and it can't prove the login still works; only a real request proves that. Claude's login is read from `CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`; Codex's from `CODEX_HOME` when set.

## Installing and updating CLIs from AFK

**Planned:** `afk harness add | update | remove | login | doctor`. AFK will install a CLI with its official installer, show the exact command and ask before running it, and open the vendor's own sign-in. It will never handle passwords.

## Adding support for a CLI

Each CLI is one entry in [`internal/harness/registry.go`](../../internal/harness/registry.go): its executable names, npm package, effort levels and flag, sign-in command, self-update argument and sign-in check. Routing and launching need an adapter in the router and in [`internal/core/launch.go`](../../internal/core/launch.go) too.
