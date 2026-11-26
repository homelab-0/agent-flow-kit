# Quick start

## 1. See what AFK found

```console
$ afk harness
Agent CLIs · 5 of 13 supported CLIs installed

  CLI       VERSION   SIGN-IN        INSTALLED WITH                    EFFORT      UPDATE WITH
  claude    2.1.332   authenticated  npm (@anthropic-ai/claude-code)  low..max    npm install -g @anthropic-ai/claude-code@latest
  codex     0.172.0   authenticated  npm (@openai/codex)              low..ultra  npm install -g @openai/codex@latest
  ...
```

AFK routes to `claude`, `codex`, `opencode`, `grok` and `agy` today. Sign in to each one with its own command (`claude auth login`, `codex login`, and so on); AFK never handles your password.

## 2. Ask what AFK would pick

```sh
afk --explain "fix the flaky retry test"
```

```text
task: coding (guessed from the prompt)  prefer: balanced
choice: claude / sonnet [effort medium]
  pool: anthropic-max (98% left, available)
  score: 98.41 LMArena Agent #3 (Best Speed/Throughput) [estimate]
  why: Selected claude/sonnet [...]
best per installed CLI:
  claude    sonnet — score 98.41, pool anthropic-max 98% left (available), subscription
  codex     gpt-6.1-sol — score 95.77, pool openai-plus 86% left (available), subscription
```

Nothing starts. See [how routing works](../guides/routing.md) for what the numbers mean.

## 3. Start a session

```sh
afk "fix the flaky retry test"
```

The [route card](../guides/route-card.md) opens. Press `↵` to start the pick, `↑`/`↓` to choose another CLI, `tab` to change the effort, `?` for the reasoning, or `esc` to cancel. The chosen CLI then owns the terminal; when it exits, AFK prints a receipt and asks how it went.

## 4. Steer it when you need to

```sh
afk --task review "look over the auth changes"    # say what kind of work it is
afk --prefer cheap "rename the config flag"        # free and local models first
afk --prefer best "design the sync protocol"       # strongest model for the kind
afk --harness codex "add retries to the client"   # only this CLI
afk -y "bump the version"                          # skip the card
```

All options are in the [command line reference](../reference/cli.md).
