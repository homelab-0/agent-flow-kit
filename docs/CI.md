# Continuous integration

`.github/workflows/tests.yml` runs the kit's offline qualification on the
dedicated self-hosted runner set `gha-agent-flow-kit`. It is a measured
diagnostic run: every failure stays a failure, and nothing this runner cannot
qualify is reported as qualified.

## When it runs

- `push` to `master`, `workflow_dispatch`, and `pull_request` from a branch of
  this repository.
- A pull request from a fork gets no job. The job-level condition requires the
  head repository to be this repository, and the runner set's own guard refuses
  forks as well.
- The workflow token is `contents: read`. No repository secrets are used.

## Environment contract

The runner image, its pinned tools and its isolation are owned by prox-ops
(image `ghcr.io/jlengelbrecht/runner-afk`, runner 2.338.0, Ubuntu 24.04 x64,
2 CPU / 4 GiB / 10 GiB, unprivileged user, all capabilities dropped, seccomp
`RuntimeDefault`, HTTPS egress to GitHub, GHCR, the Go proxy and npm only).
The workflow does not change the image or the runner's isolation.

What the workflow sets up, in order:

1. **Evidence directory** at `$RUNNER_TEMP/afk-ci-evidence`, outside the
   checkout.
2. **Checkout** with `actions/checkout` pinned to the v6.1.0 commit SHA,
   `fetch-depth: 0` and `persist-credentials: false`. Full history is
   required: the release client refuses a shallow mirror and needs the
   repository root commit `d74e7f9`.
3. **Preflight**, which fails the job explicitly rather than letting a later
   check skip:
   - runner identity and resources are recorded (`runner.txt`); the job fails
     on a non-Linux runner or when it runs as root;
   - required tools must be on `PATH`: bash, git, jq, yq, shellcheck, node,
     python3, sqlite3, perl, ssh, ssh-keygen, timeout, setsid, flock, column,
     getent, sha256sum, mktemp, tee. Versions are recorded (`tools.txt`); a
     version different from the image declaration is a warning, not a
     failure. `tools.txt` also records whether `agent-stamp-validate` is on
     `PATH` (`absent` otherwise); it is optional and never fails the job;
   - the checkout must not be shallow, `d74e7f9` must be reachable, and a
     local `master` must resolve. On a pull request checkout it is created from
     `origin/master`. The aggregate's launch-text comparison reads `master:`.
     On a push to `master`, HEAD is `master`, so that comparison is identical
     by construction and proves nothing; it is meaningful on pull requests.
     `refs.txt` records HEAD, `master`, and whether the retired dispatch code
     at `02b18d0` is reachable. When it is not, the aggregate's vacuous-grep
     control for that code is silently off; this is recorded, not failed;
   - the historical fixture must match its pinned sha256 (see below);
   - the passwd home's `.claude` directory is created empty (mode 700).
     `dispatch.sh` requires that default store to exist; nothing is put in it.
     No settings, credentials or auth files are created.
4. **Offline aggregate**: `bash tests/run-tests.sh`, with `AFK_LIVE_TESTS=0`
   and any inherited `AGENT_ROUTER_*` / `AGENT_STAMP_VALIDATE*` variables
   unset. `AFK_TEST_LOG_DIR` points at the evidence directory, so every child
   suite's full output is saved. The step's exit status is the aggregate's.
   Nothing is skipped, retried, or marked `continue-on-error`. The suite lock
   stays enabled. `suite-result.txt` says `interrupted` until the aggregate
   finishes, so a timeout or cancel is not reported as "did not run".
5. **Required checks did not skip**: the job fails if the aggregate log shows
   `shellcheck NOT RUN`, `SKIP byte-identity vs master`, or no final
   `N passed, M failed` line. Those are the only skip-based failures.
   `skips.txt` then lists, without failing, the aggregate's `SKIP` lines and
   every child suite log's `SKIP` and TAP `skip - ` lines, colour codes
   stripped and each prefixed with its log name. A passing child suite shows
   only its last line (including its `N skipped` count) in the aggregate
   log, so its skips are visible only in `skips.txt` and its suite log.
   Some child skip helpers (`lifecycle-tests.sh`, `lifecycle-mutation-tests.sh`)
   print a `SKIP` line without counting it, and a check that silently does
   nothing prints no line at all. `skips.txt` is therefore what was
   announced as skipped, not a complete list of unexercised checks. Expected
   entries include the live control-plane chain and, when
   `agent-stamp-validate` is absent, installed-validator acceptance.
6. **Standalone Node tests**: `node --test tests/*.mjs`. This step runs even
   when the aggregate failed. The aggregate's failure still fails the job.
7. **The default `.claude` store stayed empty**: the job fails if anything was
   written there and lists the names, never the contents.
8. **Resource observations and step summary**, then the **evidence upload**
   with `actions/upload-artifact` pinned to the v7.0.2 commit SHA. Both always
   run.

No step restores a cache, so each run starts from the checkout.

## Running the same commands locally

```sh
bash tests/run-tests.sh                                   # offline aggregate
AFK_TEST_LOG_DIR=/tmp/afk-logs bash tests/run-tests.sh    # plus full child logs
node --test tests/*.mjs                                   # standalone Node tests
```

With `AFK_TEST_LOG_DIR` unset, `run-tests.sh` behaves exactly as before. When
it is set, each child suite's full output goes to `<dir>/<suite>.log`, followed
by a final `# exit=<status> elapsed=<seconds>s` line. The console still shows
only the last 40 lines of a failing suite. If a requested log cannot be
written, that is reported as its own FAIL.

## Time budget versus job timeout

`run-tests.sh` warns, and never fails, when one child suite takes more than
240s or the whole run takes more than 720s. Those budgets are unchanged. On
the runner's 2 CPUs the owner measured 1376s for the aggregate, so the job's
hard limit is `timeout-minutes: 45`. A `BUDGET` line in the log is a sizing
signal. A job that hits the 45-minute limit is cancelled and shows as failed.
Wall time is recorded in `suite-result.txt`, and in `run-tests.time.txt` when
GNU `time` is present. cgroup and disk figures go in `runner.txt` and
`resources-after.txt` when readable. None of this tooling is a prerequisite.

## Historical fixture: `tests/fixtures/adapter-manager-schema-v2-245b6a4.sh`

`tests/runtime-experience-tests.sh` checks that the current adapter manager
migrates records that the schema-v2 manager wrote with relative paths. It used
to read that manager with `git show 245b6a4:adapters/manage.sh`. Commit
`245b6a4e76c4354e2f1c87a79b34d111413ddece` is not reachable from the published
history, so a full GitHub clone aborted the whole suite there.

The fixture holds the exact bytes of `adapters/manage.sh` at that commit:
blob `5aad6a76d0c9d69a5df8a4f18f626a4e7c2217bf`, 302 lines, sha256
`87c903cd6627b6e7eae3af155a5e1affe43457ec9b4a5500704cd277b5976250`. They were
recovered on a host that still holds the object. The test copies the fixture
into its temporary directory and checks the copy's sha256 and Git blob id. A
missing file or a mismatch fails the suite explicitly; otherwise the copy runs
from there, as before. The migration assertions are unchanged. The fixture is never
edited and never installed as active code.

## Not qualified on this runner

A green run says nothing about the following. Each needs its own evidence
from the named place, and none is counted as a pass here:

- **Release candidate sandbox qualification** (`tests/release-update-tests.sh`).
  The release client qualifies a candidate inside `bwrap --unshare-all`. The
  runner image has no `bwrap`. In a local Docker reproduction of the image
  (default seccomp, all capabilities dropped, unprivileged user), an installed
  `bwrap` could not create namespaces. That was not reproduced in-cluster.
  prox-ops will not loosen runner isolation for it. The client runs
  `/usr/bin/bwrap` exactly, so the workflow probes that path: whether it
  exists and whether an `--unshare-all` probe works. It records any `bwrap`
  on `PATH` separately (`sandbox.txt`), and it never reports sandbox
  qualification as passed. The verdict comes from a run on a bwrap-capable
  AFK host.
- **Installed stamp-validator acceptance**
  (`tests/make-stamp-override-tests.sh`). When `agent-stamp-validate` is not
  on `PATH` (see `tools.txt`; the image does not declare it), these checks
  print a `SKIP` line and are not exercised. An absent validator means
  unqualified, not passed.
- **The live control-plane chain** (router, validator, catalog, Paperclip,
  Orca, deployment). It needs `AFK_LIVE_TESTS=1` and real credentials and
  stays off in CI.
- **Darwin behaviour** of the release client and runtime. The runner is
  Linux only.
- **`tests/primitive-equivalence-tests.sh`**, a standalone tool that is not
  part of the aggregate. It is not run here.

## The first runs may be red

The owner's local reproduction of the image reported 975 passed and 2 failed
before this workflow existed. The two failed aggregate gates were the
runtime experience gate, which aborted on the unreachable `245b6a4` (the
fixture below addresses that), and the release update gate. Inside the
release update gate, the sandbox case failed, and so did two more cases:
`poison-resistant release check completes` (BLOCKED, expected CURRENT) and
`leader-exit descendant is drained before completion` (exit 2, expected 0).
The cause of those two is not established. The missing sandbox is one candidate; process
timing at 2 CPU is another. Nothing here claims they share a cause with the
sandbox case.

To settle it, `tests/release-update-tests.sh` now prints the retained release
result document (state and reason) for either case when it fails, before its
temporary directory is removed. Only the client's result document is printed,
never its stderr or the environment.

## Reading a run's evidence

Download the `afk-ci-evidence-<run id>-<attempt>` artifact (kept 14 days):

| File | Contents |
|---|---|
| `run-tests.log` / `run-tests.plain.log` | aggregate console output, raw and without colour codes |
| `suite-logs/<suite>.log` | each child suite's full output and exit status |
| `suite-result.txt` | aggregate exit status and wall seconds, or `interrupted` |
| `skips.txt` | announced skips: aggregate `SKIP` lines plus child `SKIP` / `skip - ` lines, each prefixed with its log name (not a complete list of unexercised checks) |
| `node-tests.log` | standalone Node test output |
| `runner.txt`, `tools.txt`, `refs.txt` | runner identity; tool versions and `agent-stamp-validate` presence; HEAD, master and `02b18d0` reachability |
| `sandbox.txt` | `bwrap` on `PATH`, `/usr/bin/bwrap` presence and namespace probe result |
| `resources-after.txt`, `run-tests.time.txt` | cgroup, disk and GNU `time` observations, when available |

For the release cases, look at `suite-logs/release-update-tests.log`. A
failed poison or leader-exit case has a `# <case>: release result {...}` line
right after its `not ok` line.

To get fresh evidence, push a new commit to the pull request branch or use
**Run workflow** (`workflow_dispatch`) on a branch of this repository. Report
the run URL. A re-run that passes does not replace a red run's evidence.
