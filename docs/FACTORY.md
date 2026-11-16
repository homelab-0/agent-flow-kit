# The software factory

The factory takes an issue from Paperclip and carries it to a merged change or to a person, with no session to attend. This page says what it does, what it refuses to do, how to configure it, and what a host has to provide.

It is the product path. The PM-session and Orca-dispatch flow described in `HANDOFF.md`, `docs/PAPERCLIP.md` and `docs/RUNTIME-EXPERIENCE.md` predates it and is not used by factory projects.

## What happens to an issue

`agent-flow-kit paperclip-poll` runs one pass. For every project with `factory_enabled: true`, the pass:

1. Reads board answers on jobs that are waiting for a person.
2. Recovers jobs whose runner died or went silent.
3. Claims Todo issues, up to the project's `max_active_issues`, and runs each as a job.

A job moves through these stages. Each stage is one bounded run of an agent CLI (`claude`, `codex`, `opencode`, `agy`, `grok` or `pi`) in the job's own git worktree.

| Stage | Who | Output |
|---|---|---|
| Intake | project PM | `intake.md`: `VERDICT` (ACCEPT, NEEDS-INFO, REJECT), `RISK`, `SURFACES` |
| Spec | PM, or architect for high risk | `spec.md` |
| UX | UX designer, when the surfaces include `ui` or `ux` | `ux-spec.md` |
| Build | developer | commits on branch `factory/<job>`, `build.md` |
| Checks | the project's `.afk/checks.sh` | `round-N/checks.md` |
| Review | reviewer, plus security, UX and architecture reviews when the intake calls for them | `round-N/review-*.md` |
| Approval | the merge approver (code, not a model) | `decision.md` |

A review that asks for changes sends the job back to Build, up to `max_rounds`. The job ends `merged`, `rejected`, or `needs-human`.

Job state lives in the project checkout under `.afk/jobs/<job>/`. Worktrees live beside the checkout in `<repo>-factory/<job>/`.

## What the factory will not do

These rules hold whatever the agents write.

**A stage runs a real agent or it fails.** There is no default output. Canned stage output exists for tests only and needs `AFK_FACTORY_OFFLINE_SYNTH=1`.

**A stage the board cannot see does not start.** Before an agent starts, the issue is moved to In Progress and the stage is announced on it. If Paperclip does not accept that, the stage waits and the next pass tries again. A job waiting this way is not counted as a stall.

**A failed stage stops the job.** If intake, spec, UX or build fails or writes nothing, the job goes to `needs-human` with the reason. An intake with no readable verdict is a failure, not an acceptance. An unreadable risk is treated as high.

**Nothing merges without all of this:**

- the checks passed, on the commit being merged, and did not change the branch while they ran
- every review the round required passed; a review that did not finish counts against the merge
- the branch has committed changes and the worktree has none uncommitted
- the change is inside the diff budget and touches no protected path
- the project has a check script, or its `.afk/config.json` says `"checks": "none"`
- the project's merge authority in the Paperclip config is `pm`
- the risk is not critical

Anything else goes to a person as an approval card on the issue.

**Only the board user steers a job.** Comments from anyone else are ignored. A comment approves only when the approval is the whole comment: `approve`, `approved`, `lgtm`, `merge` or `ship it`, with or without markup or an emoji. A short comment that starts with one of those words and says something else ("Approved, thanks") gets a question back. Anything longer is treated as instructions for another round, and instructions add up across replies.

**Approving is not always merging.** A job that stopped for budget, a stall or a failed stage has nothing checked to merge; approving it lets it carry on. A change whose checks failed is not merged on approval either: the factory says so and waits for instructions.

**The evidence is about one commit.** The checks record the commit they start on. If they move the branch or change tracked files, they fail and the branch is put back. The runner keeps that commit itself and restores the record before the approver reads it, because agents can write the job directory. Both landing paths merge only that commit, and a branch that has moved since is refused. A board approval is checked again under the job lock before anything lands.

**On GitHub, the factory waits.** It opens a pull request, waits for its checks, and merges exactly the checked commit, with a subject and body it writes itself. A failed or unreadable check, or a merge GitHub refuses, goes to a person.

**One runner per job.** The poll pass, the watchdog, review sync and `factory resume` can all reach a job. A lock in the job directory names the runner by host, PID, start time and boot, so a second runner is refused and a PID reused after a restart is not mistaken for the first. A runner recorded by another host is never signalled; its lock is taken over only after its heartbeat goes stale. A merged or rejected job is never run again.

**Every job gets its own worktree.** If one cannot be created, the job stops and no agent starts. A directory already at the job's path is used only if git lists it as this repository's worktree on the job's branch.

**Every agent run is bounded.** No stage starts on a host without `timeout` or `gtimeout`. A stage that fails or runs out of time leaves no output behind, so a review that wrote a pass and then failed counts as missing.

## Recovery

A pass can be killed at any point. On the next pass:

- A job whose runner is gone is picked up from the stage files it already wrote.
- A runner that has written no heartbeat for `watchdog.stale_seconds` is stopped, with every process it started, and the job is picked up the same way. Heartbeats are written every 60 seconds while a stage or the checks run.
- A job that has been recovered more than `watchdog.max_nudges` times in the same stage goes to a person. The count is kept in the job record, so a job that dies at the checks every time is stopped even though each attempt builds again first.

A merge is recorded in the job file the moment it lands, before any other call.

`agent-flow-kit factory resume` does the pickup on demand. `agent-flow-kit factory watchdog --dry-run` shows what a pass would do.

## Configuration

### Paperclip config: `~/.config/agent-flow-kit/paperclip.json`

Per project:

| Field | Meaning |
|---|---|
| `slug`, `paperclip_project_id`, `repo_path` | which project, and its checkout |
| `factory_enabled` | `true` turns the factory on for the project. Only a JSON `true` counts |
| `merge` | `pm`: a clean change merges unattended. `human`, or absent: a person merges every change |
| `max_active_issues` | how many jobs run at once |
| `harness` | the agent CLI recorded for the project's hired agents |

At the top level, `host.github_token_ref` names the GitHub token the factory pushes, opens pull requests and merges with: `op://...` for 1Password, or `file:/absolute/path` for a file only its owner can read. Use a bot account's fine-grained token limited to the factory's repositories (Contents and Pull requests read and write, Metadata read). The origin must be https. Without it the factory uses the host's own `gh` login. If it is set and cannot be read, nothing is pushed. Agent stages never get a GitHub token from the factory's environment.

### Project config: `<repo>/.afk/config.json`

`agent-flow-kit factory init --repo <path>` writes it with the defaults, along with `.afk/checks.sh`. Commit both. A tracked check script is run as committed on the base, and if it cannot be read out the checks fail. An untracked one runs from the base checkout, but only while it still matches the copy the job started with; when the board asks for another round, the script as it is then is taken. A key the file leaves out keeps its default.

| Key | Default | Meaning |
|---|---|---|
| `max_rounds` | 2 | build and review rounds before a person is asked |
| `merge_policy` | `situational` | `human` sends every change to a person |
| `land` | `auto` | `auto`: pull request when origin is GitHub, else a local merge. `local`: always a local merge |
| `land_checks` | `wait` | `skip` merges without waiting for pull request checks |
| `land_checks_timeout_sec` | 1200 | how long to wait for them |
| `diff_budget.max_lines`, `.max_files` | 800, 25 | over either, a person merges |
| `protected_paths` | CI workflows, `CODEOWNERS`, migrations, `.afk/checks.sh`, `.afk/config.json`, and more | a touched path that contains one of these goes to a person |
| `gate_timeout_sec` | 3600 | limit on `.afk/checks.sh` |
| `watchdog.stage_timeout_sec` | 900 | limit on one agent run |
| `watchdog.free_stage_timeout_sec` | 120 | the same, for free-tier models |
| `watchdog.stale_seconds` | 900 | silence before a runner is called stalled |
| `watchdog.max_nudges` | 2 | recoveries in one stage before a person is asked |
| `checks` | | `none` lets a project with no `.afk/checks.sh` merge unattended; otherwise such a change goes to a person |
| `queue`, `queue_label` | `todo`, `factory` | `label`: only Todo issues carrying the label are claimed |
| `router.allow_free_reviewers` | false | let free and local models review |
| `router.prefer_free_for_low_risk` | false | prefer free models for low-risk builds |
| `router.*` | | see Routing |

### Environment

| Variable | Effect |
|---|---|
| `AFK_HARNESS_BIN_DIR_OVERRIDE` | look for agent CLIs in this directory only |
| `AFK_HARNESS_UPDATES=off` | `factory update-harnesses` refuses; for hosts where the CLIs are pinned |
| `AFK_LITELLM_BASE_URL` | the model gateway; unset means subscription CLIs only |
| `AFK_SKIP_BENCHMARK_AUTOSYNC=1` | never refresh benchmarks automatically |
| `AFK_BENCHMARK_TTL_SEC`, `AFK_BENCHMARK_RETRY_SEC`, `AFK_BENCHMARK_CARRY_SEC` | benchmark refresh age (24h), retry spacing after a failed sync (15m), how long a measured score outlives an unreachable feed (14d) |
| `AFK_STAGE_TIMEOUT_SEC`, `AFK_GATE_TIMEOUT_SEC`, `AFK_WATCHDOG_STALE_SEC`, `AFK_WATCHDOG_MAX_NUDGES` | override the matching config keys |

## Routing

Each stage is routed when it starts. The router scores every candidate it can launch and takes the highest.

A candidate is a model on an installed, logged-in CLI. Its score is a benchmark figure for the kind of work the stage is, adjusted for:

- how much of the subscription pool behind it is left
- cost: free and local models are preferred for low-risk work when that is switched on
- independence: a reviewer from a different model family than the builder is preferred
- reservation: the largest models are kept for high-risk, security and architecture work
- the reviewer floor: a review, which an unattended merge rests on, never goes to a free or local model unless the project sets `router.allow_free_reviewers`

A candidate is left out when its CLI is missing, its pool is exhausted or signed out, or the model was recently refused.

### Where the benchmark figures come from

`files/model-router/benchmarks.json` lists the candidates with a fixed estimate per kind of work. `agent-flow-kit factory sync-benchmarks` refreshes a copy in `~/.config/afk/benchmarks.json` from the LMArena leaderboards (agent, webdev and text) and context limits from models.dev. It runs automatically when the copy is older than a day.

- A model is matched by its whole leaderboard name, ignoring the effort suffix, and takes its best-ranked row.
- A model a reachable board does not list is held below the last rank on it.
- When a feed is unreachable, the scores it gave last time are kept for 14 days. When no board answers, the catalog is left as it is.
- Complex coding, review, architecture, web and research scores are measured; a review takes the same agent-board score as a complex build, because an unattended merge rests on it. Standard coding, security and frontier scores are fixed estimates, so cheap and local models stay in play for low-risk builds.
- A model behind the gateway (`AFK_LITELLM_BASE_URL`) is a candidate only while the gateway lists its exact model id.

Every route records which it used: `benchmark_basis` is `measured`, `capped`, `estimate`, or `stale` for a measurement older than the carry window. `agent-flow-kit factory route-preview` shows the route a stage would take, and the sync receipt lists candidates the agent board did not match.

A failed attempt marks the pool: a day for a sign-in failure, an hour for a rate limit, fifteen minutes otherwise. The stage is routed again, up to three attempts.

## What a host must provide

- **Tools**: bash 4.2 or later, jq 1.6 or later, git, curl, GNU coreutils (`timeout`, `stat`, `sha256sum`, `realpath`), `gh` for GitHub projects, `op` for the Paperclip key, and the agent CLIs.
- **A persistent home directory** holding `~/.local/state/agent-flow-kit/`, `~/.config/agent-flow-kit/`, `~/.config/afk/`, the CLI login stores, every project checkout and its `<repo>-factory/` sibling. Paths must be the same after every restart.
- **A stable hostname and `/etc/machine-id`.**
- **One instance.** Two hosts on one project race for its issues, and two processes on one volume are only kept apart per job.
- **A scheduler that runs one `paperclip-poll` at a time**, about every 90 seconds, with no time limit on a pass. A pass does not return until the jobs it started have finished.
- **A filesystem with atomic rename and exclusive `mkdir`.**

`agent-flow-kit paperclip-timer --install` sets the scheduler up on a host with a systemd user manager. On a host without one, run the poll from any supervisor that meets the rule above.

### Liveness

`agent-flow-kit factory alive [--stale-seconds N] [--json]` exits 0 while the host has shown a sign of life in the last N seconds (default 1800, or `AFK_FACTORY_ALIVE_MAX_SEC`), and 1 otherwise. Every poll pass touches `$AFK_STATE_DIR/paperclip/alive` when it starts and ends, and a running job touches it with each heartbeat. The state directory defaults to `~/.local/state/agent-flow-kit` and follows `XDG_STATE_HOME`. Run the probe with the same `HOME`, `XDG_STATE_HOME` and `AFK_STATE_DIR` as the poller, or it reads another file.

Every agent run, the checks, and each `git` and `gh` call while landing have a time limit (`AFK_FACTORY_NET_TIMEOUT_SEC`, default 120, for the landing calls). A job therefore cannot keep the file fresh for ever, and a pass that hangs stops touching it.

The file exists only after the first pass on a configured host. Give the probe an initial delay of at least one poll interval. On a host whose Paperclip config is missing or refused, the probe fails until the host is configured.

## Known limits

- Every stage runs as the same user as the poller. Agents get no GitHub token through their environment, but they can read anything that user can, including a `gh` login stored on the host and the file `host.github_token_ref` names. Give the host only the bot token, not a personal login.
- A runner on another host cannot be signalled. Its lock is taken over after `watchdog.stale_seconds` without a heartbeat, so an agent it left behind can overlap the new runner by up to the stage limit minus that window. Set `stale_seconds` above `stage_timeout_sec` to rule that out.
- A job that resumes at review after its runner died has no in-memory record of the checked commit and trusts the file in the job directory.
- A repository with no `.afk/checks.sh` passes the checks stage, so its changes go to a person unless it declares `"checks": "none"`.
- A pull request merged by hand on GitHub is noticed only when the job next tries to land.
