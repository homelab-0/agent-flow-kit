# Install

AFK is a single Go program, `afk`. It needs at least one supported agent CLI installed and signed in (see [harnesses](../guides/harnesses.md)).

## From source

You need Go 1.26 or newer.

```sh
git clone https://github.com/homelab-0/agent-flow-kit.git
cd agent-flow-kit
CGO_ENABLED=0 go build -o ~/.local/bin/afk ./cmd/afk
```

Make sure `~/.local/bin` is on your `PATH`, then check what AFK finds:

```sh
afk harness
```

That is all AFK needs: the route card, `-p`, `--explain`, `--launch-plan`, `afk harness` and `afk bench sync` run entirely in the `afk` binary. Nothing else (no `bash`, `jq`, `yq` or `curl`) has to be installed.

## Settings

AFK needs no configuration. When you want some, `afk config set route.prefer cheap` creates `~/.config/afk/config.toml`; see the [configuration reference](../reference/configuration.md).

### Coming from an older AFK

If you have `~/.config/afk/router.json`, migrate it first: it keeps working only for as long as `config.toml` doesn't exist, so `afk config set` and `afk config edit` refuse to create config.toml until you do. To move to config.toml:

```sh
afk config migrate --dry-run   # shows the diff, writes nothing
afk config migrate             # writes config.toml
```

The old file is not deleted or changed, but once `config.toml` exists it is no longer read. A gateway key is never copied, only the name of the variable that holds it.

## Packaged installs

**Planned.** Prebuilt binaries for Linux, macOS and Windows, published through:

- npm: `npx agent-flow-kit` to run without installing, `npm install -g agent-flow-kit` for the `afk` command. The package carries native binaries per platform; nothing is downloaded after install.
- Homebrew: `brew install jlengelbrecht/tap/afk`
- An install script and GitHub release archives
- `afk update` to move to the latest release

## Uninstall

Delete the binary. AFK's own files live under `~/.config/afk/` (`config.toml`, `afk.lock`, caches, signals and run records; `$XDG_CONFIG_HOME/afk/` when that is set, and the file `AFK_CONFIG` names if you use it), `~/.local/state/afk/` (`$XDG_STATE_HOME/afk/`) and `~/.local/state/agent-flow-kit/` (the separate Claude config directory used for gateway routes); delete them too if you want nothing left. AFK does not change your agent CLIs' own settings.
