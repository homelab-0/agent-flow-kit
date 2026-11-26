# Install

AFK is a single Go program, `afk`. It needs at least one supported agent CLI installed and signed in (see [harnesses](../guides/harnesses.md)).

## From source

You need Go 1.26 or newer.

```sh
git clone https://github.com/jlengelbrecht/agent-flow-kit.git
cd agent-flow-kit
CGO_ENABLED=0 go build -o ~/.local/bin/afk ./cmd/afk
```

Make sure `~/.local/bin` is on your `PATH`, then check what AFK finds:

```sh
afk harness
```

That is all the route card, `--explain`, `--launch-plan` and `afk harness` need. They run entirely in the `afk` binary.

### One-shot answers (`-p`)

`afk -p` still uses the bash engine in this repository while its failover is ported to Go. To use it, point AFK at the engine:

```sh
export AFK_ENGINE="$HOME/path/to/agent-flow-kit/bin/agent-flow-kit"
```

The bash engine needs `bash` 4 or newer, `jq` and `curl`. AFK looks for it in `$AFK_ENGINE`, then next to the `afk` binary, then on `PATH`.

## Packaged installs

**Planned.** Prebuilt binaries for Linux, macOS and Windows, published through:

- npm: `npx agent-flow-kit` to run without installing, `npm install -g agent-flow-kit` for the `afk` command. The package carries native binaries per platform; nothing is downloaded after install.
- Homebrew: `brew install jlengelbrecht/tap/afk`
- An install script and GitHub release archives
- `afk update` to move to the latest release

## Uninstall

Delete the binary. AFK's own files live under `~/.config/afk/` (caches, signals and run records) and `~/.local/state/agent-flow-kit/` (the separate Claude config directory used for gateway routes); delete them too if you want nothing left. AFK does not change your agent CLIs' own settings.
