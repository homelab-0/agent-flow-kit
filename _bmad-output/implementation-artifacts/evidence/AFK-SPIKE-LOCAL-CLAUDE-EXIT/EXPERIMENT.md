# EXPERIMENT — AFK-SPIKE-LOCAL-CLAUDE-EXIT

Predeclared before the first live run. Deviations are appended at the bottom,
never edited into the matrix above.

## Question under test

What keeps a gateway-backed `claude -p` session that has finished its work from
producing a result envelope and exiting? Primary hypothesis: `--output-format
json` waits for something the non-Anthropic endpoint never sends.

## System under test

The frozen gateway launch built by `build_claude_gateway_command`
(`files/model-router/scripts/dispatch.sh:165-186`). The canary reproduces that
command text directly. It does not run `dispatch.sh`, does not use the kit's
5400-second launch path, and edits nothing under `files/`.

Baseline command shape (credential resolved inside a command substitution,
never in argv, never printed):

```
set +x
ANTHROPIC_AUTH_TOKEN="$(. ~/.op-agent-env && op read op://develop/agw-claude-code/password)"
[ -n "$ANTHROPIC_AUTH_TOKEN" ] || exit 78
env -i HOME=... PATH=... USER=... LANG=C.UTF-8 TERM=dumb \
  ANTHROPIC_BASE_URL=https://ai-gateway.homelab0.org \
  ANTHROPIC_AUTH_TOKEN="$ANTHROPIC_AUTH_TOKEN" \
  ANTHROPIC_MODEL=qwen36-27b \
  ANTHROPIC_CUSTOM_HEADERS="x-placement: <verbatim from POST /v1/place>" \
  CLAUDE_CODE_MAX_CONTEXT_TOKENS=65536 \
  claude -p "$(cat -- <prompt file>)" \
  --model qwen36-27b --effort medium \
  --permission-mode acceptEdits --tools "Read,Glob,Grep,Write" \
  --strict-mcp-config --output-format json < /dev/null > <result file>
echo "CLAUDE_EXIT=$?"
```

## Controls held byte-identical across cells

Model (`qwen36-27b`), effort (`medium`), persona (absent in every cell),
permission mode (`acceptEdits`), tool set (`Read,Glob,Grep,Write`),
`--strict-mcp-config`, stdin (`< /dev/null`), gateway base URL, context cap
(65536, the catalog `min_context` for `local-code-standard`), `env -i`
allowlist, prompt bytes, and the per-cell working directory layout. Placement
is fetched per cell from `POST /v1/place` and the `x-placement` header is
copied verbatim; the resolved placement is recorded per cell.

The prompt is one tiny deterministic authoring task: write one short declared
file into the cell's own directory, then report completion. It is identical
across all cells; only the cell directory in the path differs, which is
structurally required for isolation and is recorded as such.

## Matrix

| Cell | Independent variable | Everything else |
| --- | --- | --- |
| 1 | `--output-format json` (the frozen shape) | baseline |
| 2 | `--output-format stream-json --verbose` | identical to cell 1 |
| 3 | stdin — run only if cells 1-2 do not isolate the cause | identical to the cell it is compared with |
| 4 | tool set — run only if still unresolved; `Edit` is NOT added | identical to the cell it is compared with |

Maximum four live cells. Each cell runs under an outer `timeout -k 10 600`
(10 minutes). Total live budget: 40 minutes.

## Stop rule

Stop as soon as a controlled pair demonstrates the causal condition — i.e. two
cells differing in exactly one variable where one produces an observed terminal
signal and process exit and the other does not. Cells 3 and 4 are not run in
that case.

## What counts as a result (fail-closed vocabulary)

Three distinct events, never conflated:

1. **The model stopped generating** — the endpoint returned its last token.
2. **The CLI emitted a terminal envelope** — a parseable terminal record on
   stdout (`type":"result"` for stream-json; the single result object for json).
3. **The wrapper observed process exit** — the outer timeout did not fire and
   an exit status was produced.

A timeout is evidence, not permission to infer success. The appearance of the
declared output file is observation only and never a completion signal.

## Retained per cell

Secret-free command shape, claude version, requested and served model,
resolved placement, start/end timestamps (UTC), outer-timeout result, process
exit status, stdout/stderr byte sizes and sha256, terminal-event presence and
type, tool-call sequence, and declared-file state. Raw streams are redacted
before commit. No environment dumps, no authorization headers, no credential
values.

## Deviations

(appended as they occur)

### Deviation 1 — cells 3 and 4 retargeted (recorded 2026-09-09, after cell 2)

Cells 1 and 2 both terminated: exit 0, a terminal result envelope, and the
declared file written, at 54s and 13s respectively, both at `num_turns: 2`.
The predeclared trigger for cells 3-4 ("only if cells 1-2 do not isolate the
cause") is therefore met, but the two predeclared variables — stdin and tool
set — are no longer the best use of the remaining budget: neither can explain a
non-exit that the baseline shape did not reproduce at all.

The field reports all describe long, many-turn sessions (30-87 minutes). The
one dimension the canary held far below the field condition is TURN COUNT and
session length, not output format. Cells 3 and 4 are therefore retargeted to a
controlled pair on output format at a HIGHER TURN COUNT:

| Cell | Independent variable | Everything else |
| --- | --- | --- |
| 3 | `--output-format json`, multi-turn authoring prompt | baseline-identical otherwise |
| 4 | `--output-format stream-json --verbose`, same multi-turn prompt | identical to cell 3 |

The multi-turn prompt is identical between cells 3 and 4, so the pair is still
controlled on exactly one variable. It differs from the cells 1-2 prompt, so
cells 3-4 are NOT a controlled comparison against cells 1-2 on prompt content;
they are compared with each other. Stdin and tool set are consequently
`NOT_TESTED`.
