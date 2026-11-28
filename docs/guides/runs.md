# Run records and receipts

Every session started from the route card is recorded, so you can see later what ran, where, and how it went.

## Where

`~/.config/afk/state/runs/<id>.json` (or `$XDG_CONFIG_HOME/afk/state/runs/`). The id is reserved when the session starts and shown on the launch line.

## What's in a record

Schema `afk-run/1`:

| Field | Meaning |
|---|---|
| `id` | the run id |
| `started_at`, `ended_at`, `duration_s` | when it ran |
| `where` | where it ran: `here`, or `serve` for a call answered by [`afk serve`](serve.md) |
| `key` | for a served call, the name of the API key it came in with |
| `route` | the full route that was launched; a gateway address keeps its host but loses any user info |
| `exit` | the CLI's exit code |
| `pool_before`, `pool_after` | the pool's headroom (%) when the card opened and after the session |
| `files_changed`, `commits` | in a git repository: files changed and commits made during the session |
| `outcome` | your answer: `solved`, `partly`, `wrong-pick`, or `null` when skipped. Ratings feed back into routing: see [your ratings](routing.md#your-ratings) |
| `session` | the CLI's own id for the session, when it reported one (absent otherwise). `/open` in AFK reopens it, and so does the CLI itself, for example `codex resume <id>` |

Values AFK couldn't know are `null`, never zero.

One-shot runs (`-p`) are not recorded.

## Planned

- `afk runs` to list and show records.
- `afk ps` and `afk watch` to see sessions that are running now and follow what the CLI is doing, read from its own transcript.
- `afk attach` to open a running session from another terminal, and background runs.
