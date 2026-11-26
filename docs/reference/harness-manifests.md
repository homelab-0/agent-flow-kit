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
| `modes.print.*` | the same table for one-shot (`-p`) runs, when it differs |

AFK only ever runs the `auth` commands and reads their exit code or output words. It never reads the credentials a CLI writes.

`afk harness login` runs `auth.login` (or `auth.device_login` with `--device`) in your terminal, and `afk harness doctor` and `login` run `auth.status`. `auth.expiry` and `auth.errors` are recorded but not used yet.
