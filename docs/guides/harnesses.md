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
- **Sign-in**: `signed in` or `signed out` when the CLI's own status command says so (`claude auth status`, `codex login status`; only the exit code counts). A CLI with no status command shows `login on disk` when a login file is there, which AFK can't confirm still works, `signed out` when none is, or `unknown`. The same state is in `afk harness --json` as `auth` and `auth_checked` (`status_command` or `login_file`).
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

## What AFK asks each CLI

Finding a CLI is the first step. AFK then asks each installed CLI what this account has, and routes from the answer:

| | Plan | Models | Usage |
|---|---|---|---|
| Codex | `codex app-server` (`account/rateLimits/read`) | `model/list` on the same connection, else `codex debug models` | windows, reset times and credit balance from the same call |
| Claude Code | `claude auth status` | a `list_models` control request to `claude -p --input-format stream-json`: no message is sent, so no turn runs. It does start Claude Code, so your SessionStart hooks run | only with a run, see [pools](pools.md#how-usage-is-measured); from Anthropic with the [vendor usage lookup](pools.md#the-vendor-usage-lookup) on |
| Grok | from xAI, with the lookup on | `grok models` | not reported by the CLI; from xAI with the [vendor usage lookup](pools.md#the-vendor-usage-lookup) on |
| Antigravity | not reported | `agy models` | `agy -p /usage --output-format json`, a local command that runs no turn |
| OpenCode | n/a | `opencode models` | n/a |

Two rules follow from the model list:

- **A CLI that listed its models is routed only to those.** If your Antigravity plan doesn't include a model, `agy models` leaves it out and AFK never offers it, whatever the benchmark catalog says.
- **A listed model with no benchmark is still offered**, marked `no benchmark`. It ranks below rated models and no score is shown for it.

A CLI that lists nothing (its command failed, or it has none) is routed from the catalog, as before.

AFK keeps each answer for five minutes. `afk harness scan` asks every installed CLI again at once and prints what each said: its sign-in, how many models it listed, its plan and which limits the plan has. `discovery.auto = false` (the `discovery.auto` row on the Config tab) stops AFK asking by itself: the last answers are then used until you scan.

A plan whose CLI lists its limits and has no 5-hour one is shown as `no 5-hour limit` (`no limit` on the Runs tab), which is different from `unknown`: AFK says it only when the CLI's own report lists the plan's windows and that one isn't there.

None of this sends a prompt. A login file is opened only for a CLI whose vendor usage lookup you turned on. `afk pools --json` shows what each CLI reported under `harnesses`.

## Adding support for a CLI

Each CLI is one [manifest](../reference/harness-manifests.md) in [`internal/harness/manifests/`](../../internal/harness/manifests/): its executable names, npm package, effort levels, sign-in commands, permission-mode flags and, when it has one, the command that lists its models (`[model_list]`, with `format` one of `codex-json`, `grok-text`, `tsv` or `lines`). If a release changes that command, an [override file](../reference/harness-manifests.md#overriding-a-manifest) fixes it without a new AFK. The command's first word must be one of the CLI's own executable names, and it needs at least one argument. For Codex the app server's model list comes first, so the command is used only when the app server gives no models.

A CLI that reports more (a plan, usage windows, credits) gets a module of its own: one file in [`internal/harness/`](../../internal/harness/) (`account_codex.go`, `account_claude.go`, `account_grok.go`, `account_agy.go`) that implements `Reporter` and returns an `Account`. The comment at the top of each file says which CLI version it was checked against. When a CLI changes how it reports, that file is the only one to change; the router reads the `Account` and knows nothing about how it was obtained.

A sign-in check that needs code goes in `authChecks` in [`internal/harness/registry.go`](../../internal/harness/registry.go). Launching needs an adapter in [`internal/core/launch.go`](../../internal/core/launch.go) too.
