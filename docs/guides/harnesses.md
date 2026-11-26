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

On your `PATH` first, then the usual install folders (`~/.local/bin`, `~/.bun/bin`, `~/.cargo/bin`, `~/.npm-global/bin`, the mise shims, and the Grok and OpenCode installers' own folders), then `/opt/homebrew/bin`, `/usr/local/bin` and Linuxbrew. A relative `PATH` entry (`.` or an empty one) is skipped, so a file named `claude` in a project you opened is never taken for the CLI. Set `AFK_HARNESS_BIN_DIR` to make one folder the only place AFK looks; that is useful in containers and tests.

### Sign-in states

| State | Means |
|---|---|
| `authenticated` | the CLI's own login file exists and is larger than 4 bytes |
| `signed_out` | the login file is missing, or 4 bytes or less (an empty `{}` left by signing out); AFK shows the command to sign in |
| `unknown` | AFK can't tell: the CLI has no reliable on-disk check, the file can't be checked, or the login is in the macOS Keychain |
| `not_installed` | the CLI isn't here |

The check only looks at whether the login file is there. AFK never opens it, so it never reads, prints or stores a token, and it can't prove the login still works; only a real request proves that. Claude's login is read from `CLAUDE_CONFIG_DIR` when set, otherwise `~/.claude`; Codex's from `CODEX_HOME` when set.

## Installing and updating CLIs from AFK

| Command | What it does |
|---|---|
| `afk harness doctor [name] [--json]` | checks each installed CLI: its version, its sign-in through the CLI's own status command (only the exit code counts; `claude auth status`, `codex login status`), whether its `--help` still lists the flags its [permission modes](permissions.md) use, and whether its version differs from the one those flags were checked on. Exits 1 when something needs attention |
| `afk harness login <name> [--device]` | runs the CLI's own sign-in in this terminal (`--device` for the sign-in that works without a local browser, where the CLI has one), then checks it with the status command. The prompts are the CLI's; AFK sees nothing you type |
| `afk harness add <name> [--version V]` | installs a CLI from its vendor's npm package, at an exact version (`latest` is looked up once and pinned), and records it in [`afk.lock`](../reference/configuration.md#afklock) with npm's integrity hash |
| `afk harness update <name>` | updates it the way it was installed: npm, pinned to the new latest, for one AFK installed or one installed with npm; otherwise the CLI's own updater (`claude update`, `brew upgrade …`) |
| `afk harness remove <name>` | uninstalls a CLI that AFK installed (it is in afk.lock); one you installed yourself is left alone, with how to remove it |

`add`, `update` and `remove` show the exact command first, including the install scripts an npm package runs, and ask once; `-y` skips the question, and without a terminal they need `-y`. `--dry-run` shows the plan and runs nothing; `--json` prints it. A CLI that isn't on npm (Grok, Antigravity, Cursor, Kiro, Devin) isn't installed by AFK: install it as its vendor describes and AFK finds it.

Three things keep an install from pulling in something you didn't mean to:

- **npm runs in a directory of AFK's own**, not the project you're in. npm reads a `.npmrc` from the directory it runs in, and a repository's `.npmrc` can point at another registry. Your own `~/.npmrc` still applies.
- **A new release waits 3 days.** When `latest` was published less than 3 days ago, `add` and `update` plan the newest release that is older than that, and say so. A bad or hijacked release is usually pulled within days. `--version V` installs any version now, and `AFK_RELEASE_COOLDOWN_DAYS` changes the wait (`0` turns it off). `update` never goes below the version you have: it says nothing newer is ready yet.
- **A version's hash can't change.** If npm gives a different integrity hash for the exact version `afk.lock` recorded, nothing is installed and AFK says so.

AFK never handles a password or a token: signing in is always the CLI's own.

## Adding support for a CLI

Each CLI is one [manifest](../reference/harness-manifests.md) in [`internal/harness/manifests/`](../../internal/harness/manifests/): its executable names, npm package, effort levels, sign-in commands and permission-mode flags. A sign-in check that needs code goes in `authChecks` in [`internal/harness/registry.go`](../../internal/harness/registry.go). Routing and launching need an adapter in the router and in [`internal/core/launch.go`](../../internal/core/launch.go) too.
