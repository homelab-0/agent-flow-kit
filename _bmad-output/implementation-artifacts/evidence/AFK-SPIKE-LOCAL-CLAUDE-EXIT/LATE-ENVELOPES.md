# LATE-ENVELOPES — the two field result envelopes that arrived after the timeout

Retained metadata only. The source files live in the surviving ai-control-plane
worktrees and were read without modification; neither is copied here. No result
prose, no session or message identifiers, no tool-use identifiers, no
environment or credential material is retained. Every field below is a numeric
or enumerated envelope member.

The spike's four live cells (2026-09-09) were run and committed at `831564e`
before the coordinator discovered that the two `<story>.md.claude-result.json`
files reported as zero bytes at dispatch time had since become complete,
parseable envelopes. This file is the evidence those corrections cite.

## Sources

| Field | Story 4.6 | Story 4.4a |
| --- | --- | --- |
| Path | `/home/devbox/orca/workspaces/ai-control-plane/story-4-6-registry-proposal/_bmad-output/implementation-artifacts/stories/story-4.6-registry-proposal-contract.md.claude-result.json` | `/home/devbox/orca/workspaces/ai-control-plane/story-4-4a-identity/_bmad-output/implementation-artifacts/stories/story-4.4a-identity-contract.md.claude-result.json` |
| sha256 | `03965bc7b687a4b0df5369528f40cc524c155e530bd042f3628bf35a23401898` | `8993d1feeaa64d380b257f8c6b6518bbe5b4c40c1b7002a30e45bc63846f3635` |
| Observed size | 6,213 bytes | 4,313 bytes |
| Observed mtime | 2026-09-08 14:42:31 -0400 | 2026-09-08 16:13:59 -0400 |

Both digests match the ones the correction story declared, so the files read
here are the files the coordinator saw.

## Selected envelope fields

| Field | Story 4.6 | Story 4.4a |
| --- | --- | --- |
| `type` | `result` | `result` |
| `subtype` | `success` | `success` |
| `is_error` | `false` | `false` |
| `num_turns` | 142 | 106 |
| `duration_ms` | 5,604,632 | 5,743,774 |
| `duration_api_ms` | 5,587,388 | 5,731,151 |
| `modelUsage` key | `qwen36-27b` | `qwen36-27b` |
| `contextWindow` | 65,536 | 65,536 |
| `maxOutputTokens` | 32,000 | 32,000 |
| `permission_denials` | 8 | 10 |

Envelope `usage`, which the spike already showed is cumulative across the
session rather than final-call occupancy:

| Member | Story 4.6 | Story 4.4a |
| --- | --- | --- |
| `input_tokens` | 304,999 | 273,338 |
| `cache_read_input_tokens` | 1,972,623 | 1,134,066 |
| `cache_creation_input_tokens` | 0 | 0 |
| `output_tokens` | 23,613 | 26,008 |
| Settled occupancy-member sum | 2,277,622 | 1,407,404 |
| Sum ÷ 65,536-token window | 34.8× | 21.5× |

## Timeout delta

The dispatcher stops waiting at 5,400,000 ms.

| Run | `duration_ms` | Overrun past 5,400,000 ms |
| --- | --- | --- |
| 4.6 | 5,604,632 (93m 24.6s) | 204,632 ms — 3m 24.6s |
| 4.4a | 5,743,774 (95m 43.8s) | 343,774 ms — 5m 43.8s |

`duration_api_ms` is 99.7% and 99.8% of `duration_ms` in the two runs, so
essentially the whole wall time was spent in model or tool round-trips, not
idle after the last one. Stated as a bound: `duration_ms − duration_api_ms` is
17,244 ms for 4.6 and 12,623 ms for 4.4a, the total non-API time inside each
harness's own measured lifetime. It bounds in-harness idle; it does not date the
last model event against process exit.

## What follows from this, and what does not

**Follows.**

- Both field sessions terminated normally. Each wrote a single
  `{"type":"result","subtype":"success","is_error":false}` envelope, so `json`
  did produce its terminal record; the harness process ran to completion and
  released the redirect target.
- The launched process therefore survived the dispatch timeout. `dispatch.sh`
  returned exit 2 at 5,400,000 ms while the process kept running, kept calling
  the gateway, and later wrote to a path the dispatcher had already given up on.
- The narrow cause of the reported defect is a workload/timeout mismatch: a
  90-minute launch bound against sessions that needed 142 turns and 93 minutes
  (4.6) and 106 turns and 96 minutes (4.4a). Under `--output-format json`
  nothing is written until the end, so
  the dispatcher saw a zero-byte file and had no progress signal to distinguish
  "still working" from "hung".
- The cumulative-`usage` finding reproduces at field scale and is far worse
  there than in the canary: the settled occupancy-member sums are 34.8× and
  21.5× the window, against 5.06× in cell 3.

**Does not follow.**

- Nothing here dates the last model event relative to process exit. The
  envelope carries totals, not a timeline, so "the model stopped generating
  long before the process exited" remains untested — as does its opposite.
- Nothing here shows the sessions would have finished under any smaller bound,
  or that a different output format would have made them finish sooner. Both
  ran to their own natural end at 93 and 96 minutes.
- Nothing here weakens the fail-closed rule. At the moment the dispatcher gave
  up, the file on disk was zero bytes and no terminal event had been observed;
  refusing to synthesise a result was correct then and is correct now. A late
  file is exactly the artifact a completion-by-file-inspection rule would have
  misread — in the other direction, earlier, when the declared outputs already
  existed and the envelope did not.
