# Skills

AFK keeps one copy of every skill and copies it into each agent CLI you have installed. Write or change a skill once, run `afk skills sync`, and Claude Code, Codex, OpenCode, pi, Gemini CLI and Copilot CLI all have it.

## Where skills live

- **Central copy:** `~/.config/afk/skills/<name>/SKILL.md`, plus any other files the skill needs. (`$XDG_CONFIG_HOME/afk/skills` when that is set.)
- **Each CLI's copy:** the CLI's own skills folder, from its [manifest](../reference/harness-manifests.md#skills):

| CLI | Skills folder |
|---|---|
| Claude Code | `$CLAUDE_CONFIG_DIR/skills`, else `~/.claude/skills` |
| Codex | `$CODEX_HOME/skills`, else `~/.codex/skills` |
| OpenCode | `~/.config/opencode/skills` |
| pi | `~/.pi/agent/skills` |
| Gemini CLI | `~/.gemini/skills` |
| Copilot CLI | `~/.copilot/skills` |
| Grok CLI, Antigravity | not supported (shown as `–`) |

Only Claude Code's folder has been checked against a real install. The others come from each CLI's documentation; if yours reads skills somewhere else, [override its manifest](../reference/harness-manifests.md#overriding-a-manifest).

## Commands

```text
afk skills [status] [--json]          each skill in each CLI; changes nothing
afk skills sync [--dry-run] [--json]  copy new and changed skills into the CLIs
afk skills diff <skill> <cli>         how a CLI's edited copy differs from central
afk skills keep <skill> <cli>         make a CLI's edited copy the central one
afk skills restore <skill> <cli>      put the central copy back over a CLI's edit
afk skills enable|disable <skill> <cli>   turn a skill on or off for one CLI
afk skills new <name> [description] [--edit]   start a central skill
afk skills edit <name>                open a central skill's SKILL.md in your editor
```

`enable` and `disable` only record the choice; the next `sync` adds or removes the copy.

## What a sync will and won't do

- It **adds** a central skill to each CLI that doesn't have it, and **updates** a copy AFK wrote when the central one changed.
- It **removes** AFK's copy when you turned the skill off for that CLI, or deleted it centrally.
- It **adopts** a copy you made by hand when it is identical to the central one.
- It **never touches a skill of your own** with the same name (a conflict, `!`). Rename one of them.
- It **never overwrites an edit made inside a CLI** (drift, `↻`). Look at it with `diff`, then either `keep` that copy (it becomes central, and the next sync gives it to the other CLIs) or `restore` central over it.
- It refuses skill folders that contain symbolic links, and skills over 20 MB.

AFK knows which copies it wrote from `~/.config/afk/state/skills.json`, which records each copy's content hash. Every change is made under a lock. A file or folder is first backed up under `~/.config/afk/state/backups/skills/<time>/`, the new copy is written beside the old one and moved into place, and its hash is checked. If any step fails, every change made so far is put back. The last 20 backups are kept.

## A project's own skills

A repository can keep its own skills in `.agents/skills/<name>/SKILL.md`. Most CLIs read that folder themselves: Codex, OpenCode, Pi, Copilot CLI and Gemini CLI, per their documentation. Claude Code reads `.claude/skills` instead, so AFK copies a project skill there. It lists each copy in the repository's `.git/info/exclude`, so git never sees it.

AFK asks before it installs a project skill anywhere. You have two choices:

- **This project only** (`p`): AFK copies the skill into the project folder of each CLI that needs one, for this repository only.
- **Every project** (`g`): AFK copies the skill into `~/.config/afk/skills`. From then on it is a central skill, synced into every CLI's own folder. AFK removes its project copies.

`afk skills sync` asks in a terminal, and Enter leaves a skill for later. `afk skills scope <skill> project|global` answers without a prompt. Add `--project` to `status`, `sync`, `diff`, `keep`, `restore`, `enable` or `disable` to work on the repository's skills only. In the Skills tab, a project skill waiting for an answer shows `?`, and `space` asks.

Copying into central never overwrites a different skill with the same name; AFK tells you to rename one.

## The Skills tab

Press `4` in the [control panel](control-panel.md) (or `/skills` in the composer) for the grid: one row per skill, one column per CLI under its logo. The scope column says where a skill applies: `everywhere` for central skills, `project` or `everywhere` for a project skill once you've chosen, `choose` while it waits for your choice, and `removed` when it has left central and the next sync clears AFK's copies.

| Mark | Meaning |
|---|---|
| `✓` | installed and in sync |
| `◆` | a project skill waiting for you to choose this project or every project |
| `↻` | changed in that CLI since AFK synced it |
| `○` | turned off for that CLI |
| `·` | not there |
| `–` | that CLI has no skills folder AFK knows |
| `+` | the next sync adds or updates it |
| `-` | the next sync removes AFK's copy |
| `!` | a skill of your own with that name; AFK leaves it alone |

Under the grid, a box shows the selected skill: the description from its `SKILL.md`, its folder, how many files it has and when one last changed, and what the selected CLI has of it. When the skill was edited in a CLI, the box turns to that edit.

`↑` `↓` pick a skill and `←` `→` pick a CLI. `space` turns the skill on or off for that CLI, `s` syncs everything, and `n` asks, in the tab, for a name and when to use the skill (`pr-triage Use when sorting pull requests.`) and makes it. `e` opens the selected skill's `SKILL.md` in your editor to write its steps. When the selected skill's copy has drifted, the box says where and how many lines differ: `d` shows the diff, `k` keeps that CLI's copy and `c` restores central.

