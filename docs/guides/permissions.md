# Permissions

Agent CLIs ask before they edit files or run commands. AFK keeps that behaviour by default.

## Today: ask, or yolo

- **Ask** (default): AFK starts the CLI with its own default permission behaviour; it asks you before acting.
- **Yolo**: the CLI acts without asking, using its own skip-permissions flag. Turn it on with `--yolo`, or press `y` twice on the route card (a red `yolo` tag shows it is on; `y` again turns it off). OpenCode takes yolo only in one-shot runs (`-p`); an interactive OpenCode session keeps its own prompts.

| CLI | Yolo flag AFK passes |
|---|---|
| `claude` | `--dangerously-skip-permissions` |
| `codex` | `--dangerously-bypass-approvals-and-sandbox` |
| `opencode` | `--auto` (one-shot runs) |
| `grok` | `--always-approve` |
| `agy` | `--dangerously-skip-permissions` |
| `pi` | none: Pi doesn't ask before acting, so yolo changes nothing |

AFK sets yolo for one launch only. It never writes it into a CLI's own settings.

## Planned: permission modes

One set of modes in AFK, translated into each CLI's own flags and settings:

| Mode | The CLI may |
|---|---|
| `plan` | read and propose; no edits, no commands |
| `ask` (default) | do anything, asking first (its own default) |
| `edits` | edit files in the project without asking; commands still ask |
| `auto` | edit and run commands without asking, inside a sandbox (project directory only, network blocked or asked) |
| `yolo` | anything, without asking or a sandbox |

The rules it will follow:

- **Never escalate silently.** If a CLI can't do the requested mode exactly (no sandbox, for example), AFK uses the next safer mode it can do and says so on the route card.
- **Always visible.** The mode shows on the route card, the receipt and the run record.
- **Yolo stays deliberate**: twice on the card, or allowed in config, and only in directories you trust (`afk trust add <dir>`), never in your home directory itself.
- **Where it's set**, most specific first: `--mode`, the route card, a per-task default (reviews in `plan`, for example), the project's config, your user config, then `ask`.
- **Headless and remote runs** can't answer prompts. They default to `auto` in their own git worktree, so changes land on a branch, never in your working copy.
- **Shared allow and deny lists** (for example, never `git push --force`), written into each CLI that supports them, diff first.
