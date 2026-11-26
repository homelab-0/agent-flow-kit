# Permission modes

AFK has five permission modes of its own. You pick one, and AFK turns it into the flags of whichever CLI runs, so the mode means the same thing on every CLI.

| Mode | The CLI may, without asking |
|---|---|
| `read-only` | read and search; no edits, no commands that change anything |
| `ask` (default) | nothing: it asks before acting, as each CLI does by default |
| `edits` | edit files in the project; it asks before running commands |
| `auto` | edit and run commands inside its sandbox |
| `yolo` | anything, with no prompts and no sandbox |

`ask` pins each CLI's own asking mode where the CLI has a flag for it (Claude `--permission-mode manual`, Grok `--permission-mode default`, Codex `--sandbox read-only --ask-for-approval on-request`, which asks before any write or command beyond reading), so a looser default in that CLI's settings can't turn it into something else. Agy and OpenCode have no such flag, so with them a default you set in their own settings still applies.

## What each CLI gets

Each flag was checked against the CLI's own `--help`; the version is in its [manifest](../reference/harness-manifests.md).

| Mode | `claude` (2.1.332) | `codex` (0.172.0) | `grok` (1.0.92) | `agy` (1.5.18) | `opencode` (2.4.2) | `pi` (1.6.1) |
|---|---|---|---|---|---|---|
| `read-only` | `--permission-mode plan` | `--sandbox read-only --ask-for-approval never` | `--permission-mode plan` | `--mode plan` | can't | `--tools read,grep,find,ls` |
| `ask` | `--permission-mode manual` | `--sandbox read-only --ask-for-approval on-request` | `--permission-mode default` | none | none | can't: runs `read-only` |
| `edits` | `--permission-mode acceptEdits` | can't: runs `ask` | `--permission-mode acceptEdits` | `--mode accept-edits` | can't: runs `ask` | `--tools read,grep,find,ls,edit,write` |
| `auto` | `--permission-mode auto` | `--sandbox workspace-write --ask-for-approval never` | `--permission-mode auto` | `--mode auto` | can't: runs `ask` | can't: runs `edits` |
| `yolo` | `--dangerously-skip-permissions` | `--dangerously-bypass-approvals-and-sandbox` | `--always-approve` | `--dangerously-skip-permissions` | one-shot runs only: `--auto` | none (all tools) |

One-shot runs (`-p`) use the same table, except Codex (`codex exec` takes no `--ask-for-approval`, so it can't ask: `read-only` is `--sandbox read-only`, `ask` runs `read-only` and says so, `auto` is `--sandbox workspace-write`) and OpenCode (`opencode run` takes `--auto` for `yolo`).

## A CLI that can't do the mode

When a CLI can't do the mode exactly, AFK runs the next **stricter** mode it can do, never a looser one, and says so: on the route card (`opencode: can't run in auto, running in ask`), in `afk --explain`, and on the line printed when the CLI starts. A CLI that can't do anything as strict (OpenCode in `read-only`) isn't started.

Pi never asks before acting, so it can't do `ask`: by default it runs `read-only`.

In a one-shot run, failover keeps the mode, or goes stricter: if the first CLI ran in `edits` instead of `auto`, the next one runs in `edits` too.

## Where the mode comes from

The first of these wins:

1. `--mode <mode>` on the command line, or `--yolo` (the same as `--mode yolo`).
2. `permissions.task.<kind>` in your config.toml, for that kind of task (for example `review = "read-only"`).
3. `permissions.default` in your config.toml.
4. `ask`.

A project's `.afk/config.json` can set `permissions.default` too, but only to make the mode **stricter** than steps 2 to 4 give: a cloned repository can tighten your mode, never loosen it. `--mode` still wins over it.

```toml
[permissions]
default = "edits"
task = { review = "read-only" }
```

`afk --explain` shows the mode and where it came from (`mode: edits [from permissions.default]`), and what each CLI runs it as. `--explain --json` has `mode`, `mode_source` and `mode_by_harness`.

## yolo stays deliberate

yolo runs only inside a git repository that you trust, and never with your home directory itself as the repository:

```sh
afk trust add ~/src/app      # one repository
afk trust add ~/repos        # every git repository below this folder
afk trust list
afk trust remove ~/repos
```

`afk trust add` refuses your home directory and anything above it, and a folder with no git repository in it, and prints the repositories it now covers. A directory inside a repository trusts that repository (its root is what is saved). `afk trust remove` says so when another entry, such as a parent folder, still covers the directory, because yolo then stays allowed there. Entries in `trust.repos` must be absolute paths or start with `~`. When yolo is refused, the message gives the exact `afk trust add` command that would allow it. The list is `trust.repos` in config.toml.

On the route card, `y` twice turns yolo on (a red `yolo` tag shows it; `y` again turns it off, and it stays off when you edit the prompt and the card reroutes). Outside a trusted repository, `y` says why it can't. Trust is checked again each time a yolo launch is built, so removing trust while a card is open, or between a one-shot run's retries, stops the next yolo launch.

A CLI's own skip-permissions flag given through `--pass` (for example `--pass --dangerously-skip-permissions`) counts as yolo, and so does an alias such as Codex's `--yolo`: it needs a trusted repository, and the plan reports yolo. Turning yolo off on the route card drops such a flag from the launch. Because trust is checked for the directory AFK runs in, yolo refuses a `--pass` flag that moves the CLI elsewhere (Codex `--cd`/`-C`); run AFK from that directory instead.

AFK sets the mode, so `--pass` refuses any other flag of the CLI's that would change it: Claude's `--permission-mode`, `--settings`, `--setting-sources` and `--allowedTools`; Codex's `--sandbox`, `--ask-for-approval`, `--full-auto`, `--profile` and a `-c` that sets `sandbox_mode` or `approval_policy`; Grok's `--permission-mode`; Antigravity's `--mode`; Pi's `--tools`. Such a flag would run after AFK's own and win, while the plan and the receipt still named the stricter mode. Use `--mode` instead. A yolo run in a trusted repository takes them. The lists are `modes.mode_flags`, `modes.config_flags` and `modes.config_keys` in each [manifest](../reference/harness-manifests.md).

AFK passes the mode on each launch only. It never writes a mode into a CLI's own settings.

## Planned

- One-shot runs (`-p`) defaulting to `auto` in their own git worktree, so changes land on a branch, never in your working copy. Until then `-p` uses the same mode as an interactive run (`ask` unless you set one).
- Shared allow and deny lists (for example, never `git push --force`), written into each CLI that supports them.
- The mode on the receipt and in the run record.
