# Harness manifests

Each agent CLI AFK knows is described by a manifest: a small TOML file with its name, how it is found and signed in to, and the flags for each [permission mode](../guides/permissions.md). The defaults are built into `afk` ([`internal/harness/manifests/`](../../internal/harness/manifests/)).

## Overriding a manifest

A file `~/.config/afk/harnesses/<name>.toml` (under `$XDG_CONFIG_HOME/afk/harnesses/` when that is set) overrides the fields it sets; everything else keeps the built-in value. For example, if a new Claude Code release renames a flag:

```toml
name = "claude"

[modes]
verified = "2.2.0"
auto = ["--permission-mode", "auto"]
```

`name` must match the file name. A field AFK doesn't know, or a value of the wrong type, stops AFK with an error naming the file and line. A file for a CLI AFK doesn't know is ignored with a warning: adding a new CLI still needs a change to AFK.

## Fields

| Field | Meaning |
|---|---|
| `name` | AFK's id for the CLI |
| `display`, `vendor` | what people call it, and who makes it |
| `bins` | executable names to look for, in order |
| `npm_package` | the npm package, when it's installed that way |
| `efforts`, `effort_flag` | the effort levels it takes, weakest first, and how they're passed (for display) |
| `self_update` | the argument that makes a self-managed install update itself |
| `login_note` | shown instead of a login command when signing in has no single command |
| `policy_url`, `models` | reserved: a link to the vendor's usage policy, and model hints |
| `auth.login`, `auth.device_login` | the sign-in command, and one that works without a local browser |
| `auth.status` | a command that exits 0 when signed in; only the exit code counts |
| `auth.expiry` | a command that reports when the login expires, if the CLI has one |
| `auth.errors` | words in a failed run's output that mean the login is gone |
| `modes.verified` | the CLI version the mode flags were checked against |
| `modes.read-only`, `modes.ask`, `modes.edits`, `modes.auto`, `modes.yolo` | the flags for each mode; leave a mode out when the CLI can't do it, and AFK runs the next stricter one |
| `modes.bypass_flags` | other spellings of the yolo flag (Codex `--yolo`); given through `--pass`, they make the run yolo |
| `modes.dir_flags` | flags that move the CLI to another directory (Codex `--cd`, `-C`); yolo refuses them in `--pass` |
| `modes.user_config` | flags that keep the CLI to your own settings (Claude `--setting-sources user`); added to a one-shot run outside a trusted repository |
| `modes.project_config` | `trusted` when the CLI itself loads a directory's settings only after you trusted it there (Codex), `never` when it has none; left out, or `unknown`, AFK assumes it may load them. An override uses `unknown` to undo a built-in `trusted` |
| `modes.mode_flags` | the CLI's other flags that change what it may do without asking (permission mode, sandbox, settings source, tool allowlist); `--pass` refuses them unless the run is yolo |
| `modes.config_flags`, `modes.config_keys` | flags that take a `key=value` setting (Codex `-c`), and the keys among them that change the mode; `--pass` refuses those keys, and any key below them, unless the run is yolo |
| `modes.print.*` | the same table for one-shot (`-p`) runs, when it differs; an override changes only the entries it sets |

### Skills

| Field | Meaning |
|---|---|
| `skills.dir` | where the CLI reads skills. `~/` is your home folder; `$NAME/rest` uses that variable when it is set to an absolute path. Alternatives are separated by `\|` and the first that applies wins: `"$CODEX_HOME/skills\|~/.codex/skills"`. Leave it out when the CLI has no skills folder |
| `skills.format` | `skill-md`: one folder per skill with a `SKILL.md` |
| `skills.verified` | the CLI version the folder was checked against |

See [Skills](../guides/skills.md).

AFK only ever runs the `auth` commands and reads their exit code or output words. It never reads the credentials a CLI writes.

`afk harness login` runs `auth.login` (or `auth.device_login` with `--device`) in your terminal, and `afk harness doctor` and `login` run `auth.status`. `auth.expiry` and `auth.errors` are recorded but not used yet.
