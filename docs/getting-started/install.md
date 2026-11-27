# Install

AFK is a single Go program, `afk`. It needs at least one supported agent CLI installed and signed in (see [harnesses](../guides/harnesses.md)).

## With npm

You need Node 18 or newer.

```sh
npm install -g @homelab0/afk   # installs the `afk` command
npx @homelab0/afk harness      # or run it without installing
```

`@homelab0/afk` is a small launcher. Its optional dependencies are one package per platform (`@homelab0/afk-linux-x64`, `-linux-arm64`, `-darwin-x64`, `-darwin-arm64`, `-win32-x64`, `-win32-arm64`), each holding that platform's binary, and npm installs only the one that matches your machine. There is no install script and nothing is downloaded after install. If you install with `--omit=optional`, the launcher has no binary to run and says so. Every package is published from GitHub Actions with [npm provenance](https://docs.npmjs.com/generating-provenance-statements). To check where it was built, install it in a project (`npm install @homelab0/afk`) and run `npm audit signatures` there: the command checks that project's `node_modules`, not a global install.

Release candidates are published under the `next` tag: `npm install -g @homelab0/afk@next`.

## With Go

You need Go 1.26 or newer.

```sh
go install github.com/homelab-0/agent-flow-kit/cmd/afk@latest
```

This puts `afk` in `$(go env GOBIN)` when `GOBIN` is set, and in `$(go env GOPATH)/bin` otherwise. Make sure that folder is on your `PATH`.

## From a release archive

Each [GitHub release](https://github.com/homelab-0/agent-flow-kit/releases) has `afk_<version>_<os>_<arch>.tar.gz` (`.zip` on Windows) for Linux, macOS and Windows on amd64 and arm64, a `afk_<version>_checksums.txt` file, and its cosign signature bundle `afk_<version>_checksums.txt.sigstore.json`.

To check a download, verify the checksums file was signed by this repository's release workflow, then check the archive against it:

```sh
v=0.1.0
cosign verify-blob \
  --bundle afk_${v}_checksums.txt.sigstore.json \
  --certificate-identity-regexp '^https://github.com/homelab-0/agent-flow-kit/\.github/workflows/release\.yml@refs/tags/' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  afk_${v}_checksums.txt &&
sha256sum --ignore-missing -c afk_${v}_checksums.txt   # shasum -a 256 --ignore-missing -c on macOS
```

Unpack the archive only when both checks pass, then put `afk` on your `PATH`, for example in `~/.local/bin`.

## From source

```sh
git clone https://github.com/homelab-0/agent-flow-kit.git
cd agent-flow-kit
CGO_ENABLED=0 go build -o ~/.local/bin/afk ./cmd/afk
```

Make sure `~/.local/bin` is on your `PATH`.

## Check it

```sh
afk version
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

## Updating

Run the same install command again: `npm install -g @homelab0/afk@latest`, `go install ...@latest`, or a newer archive.

## Uninstall

Run `npm uninstall -g @homelab0/afk`, or delete the binary. AFK's own files live under `~/.config/afk/` (`config.toml`, `afk.lock`, caches, signals and run records; `$XDG_CONFIG_HOME/afk/` when that is set, and the file `AFK_CONFIG` names if you use it), `~/.local/state/afk/` (`$XDG_STATE_HOME/afk/`) and `~/.local/state/agent-flow-kit/` (the separate Claude config directory used for gateway routes); delete them too if you want nothing left. AFK does not change your agent CLIs' own settings.
