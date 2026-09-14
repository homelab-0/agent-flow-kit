#!/usr/bin/env bash
# Canary runner for AFK-SPIKE-LOCAL-CLAUDE-EXIT.
#
# Reproduces build_claude_gateway_command from
# files/model-router/scripts/dispatch.sh directly, one cell at a time, under an
# outer 10-minute timeout. It does not run dispatch.sh and changes nothing the
# kit owns.
#
# usage: run-cell.sh <cell-name> <output-format-args...>
set -euo pipefail

CELL="${1:?cell name}"; shift
OUTPUT_ARGS=("$@")

BUNDLE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CELLDIR="$BUNDLE/sessions/$CELL"
mkdir -p "$CELLDIR/work"

HOME_DIR="$HOME"
CLAUDE_BIN="$(command -v claude)"
APPROVED_PATH="$(dirname "$CLAUDE_BIN"):/usr/local/bin:/usr/bin:/bin"
GATEWAY_URL="https://ai-gateway.homelab0.org"
TOKEN_REF="op://develop/agw-claude-code/password"
OP_ENV_FILE="$HOME_DIR/.op-agent-env"
MODEL="qwen36-27b"
EFFORT="medium"
MAX_CONTEXT="65536"

# ---- the identical prompt (only the cell directory differs) ----------------
PROMPT_FILE="$CELLDIR/prompt.txt"
if [ "${CANARY_PROMPT:-tiny}" = "multiturn" ]; then
cat > "$PROMPT_FILE" <<EOF
Work in the directory $CELLDIR/work.

Do these steps strictly in order, one tool call at a time:

1. Write $CELLDIR/work/note-01.md containing the single line: note 01
2. Write $CELLDIR/work/note-02.md containing the single line: note 02
3. Write $CELLDIR/work/note-03.md containing the single line: note 03
4. Write $CELLDIR/work/note-04.md containing the single line: note 04
5. Write $CELLDIR/work/note-05.md containing the single line: note 05
6. Write $CELLDIR/work/note-06.md containing the single line: note 06
7. Read each of the six files back, one Read call per file.
8. Write $CELLDIR/work/summary.md listing the six file names, one per line.

Then reply with exactly: DONE

Do nothing else. Do not read or search any file outside $CELLDIR/work.
EOF
else
cat > "$PROMPT_FILE" <<EOF
Write a file at $CELLDIR/work/canary.md whose entire contents are the single
line:

canary ok

Then reply with exactly: DONE

Do nothing else. Do not read or search any other file.
EOF
fi

# ---- placement, fresh for this cell ---------------------------------------
set +x
PLACE_EVIDENCE="$CELLDIR/placement-evidence.json"
(
  set +x
  . "$OP_ENV_FILE"
  AGENT_ROUTER_TOKEN="$(op read op://develop/caller-token/credential)"
  curl -sS -X POST https://agent-router.homelab0.org/v1/place \
    -H "Authorization: Bearer $AGENT_ROUTER_TOKEN" \
    -H 'Content-Type: application/json' --max-time 20 \
    -d '{"model_profile":"local-code-standard","placement_policy":"prefer-warm-local"}'
) > "$PLACE_EVIDENCE"
PLACEMENT_HEADER="$(jq -r '.headers["x-placement"] // ""' "$PLACE_EVIDENCE")"
[ -n "$PLACEMENT_HEADER" ] || { echo "no x-placement; refusing to launch" >&2; exit 78; }

STDOUT_FILE="$CELLDIR/stdout.raw"
STDERR_FILE="$CELLDIR/stderr.raw"
META="$CELLDIR/meta.json"

printf '%s\n' "claude version: $(claude --version)" > "$CELLDIR/versions.txt"
printf '%s\n' "placement: $PLACEMENT_HEADER" >> "$CELLDIR/versions.txt"

START="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
START_S="$(date +%s)"
RC=0
timeout -k 10 600 bash -c '
  set +x
  ANTHROPIC_AUTH_TOKEN="$(. "$1" && op read "$2")"
  [ -n "$ANTHROPIC_AUTH_TOKEN" ] || {
    echo "gateway credential resolved EMPTY; refusing to start claude unauthenticated" >&2
    exit 78; }
  shift 2
  home="$1"; path="$2"; user="$3"; base="$4"; model="$5"; eff="$6"; ph="$7"; mc="$8"; pf="$9"
  shift 9
  env -i HOME="$home" PATH="$path" USER="$user" LANG=C.UTF-8 TERM=dumb \
    ANTHROPIC_BASE_URL="$base" ANTHROPIC_AUTH_TOKEN="$ANTHROPIC_AUTH_TOKEN" \
    ANTHROPIC_MODEL="$model" \
    ANTHROPIC_CUSTOM_HEADERS="x-placement: $ph" \
    CLAUDE_CODE_MAX_CONTEXT_TOKENS="$mc" \
    claude -p "$(cat -- "$pf")" \
    --model "$model" --effort "$eff" \
    --permission-mode acceptEdits --tools "Read,Glob,Grep,Write" \
    --strict-mcp-config "$@" < /dev/null
' _ "$OP_ENV_FILE" "$TOKEN_REF" "$HOME_DIR" "$APPROVED_PATH" "$(id -un)" \
  "$GATEWAY_URL" "$MODEL" "$EFFORT" "$PLACEMENT_HEADER" "$MAX_CONTEXT" "$PROMPT_FILE" \
  "${OUTPUT_ARGS[@]}" > "$STDOUT_FILE" 2> "$STDERR_FILE" || RC=$?
END_S="$(date +%s)"
END="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

TIMED_OUT=false
if [ "$RC" = "124" ] || [ "$RC" = "137" ]; then TIMED_OUT=true; fi

jq -n \
  --arg cell "$CELL" \
  --arg args "$(printf '%s ' "${OUTPUT_ARGS[@]}")" \
  --arg start "$START" --arg end "$END" \
  --argjson elapsed "$((END_S-START_S))" \
  --argjson rc "$RC" \
  --argjson timed_out "$TIMED_OUT" \
  --argjson out_bytes "$(stat -c%s "$STDOUT_FILE")" \
  --argjson err_bytes "$(stat -c%s "$STDERR_FILE")" \
  --arg out_sha "$(sha256sum "$STDOUT_FILE" | cut -d' ' -f1)" \
  --arg err_sha "$(sha256sum "$STDERR_FILE" | cut -d' ' -f1)" \
  --arg placement "$PLACEMENT_HEADER" \
  --arg claude_version "$(claude --version)" \
  --argjson declared_files "$(ls -1 "$CELLDIR/work" 2>/dev/null | wc -l)" \
  '{cell:$cell, output_args:($args|rtrimstr(" ")), claude_version:$claude_version,
    placement:$placement, started_at:$start, ended_at:$end,
    elapsed_seconds:$elapsed, outer_timeout_seconds:600,
    outer_timeout_fired:$timed_out, process_exit_status:$rc,
    stdout_bytes:$out_bytes, stdout_sha256:$out_sha,
    stderr_bytes:$err_bytes, stderr_sha256:$err_sha,
    declared_files_written:$declared_files}' > "$META"

echo "cell=$CELL rc=$RC timed_out=$TIMED_OUT elapsed=$((END_S-START_S))s stdout=$(stat -c%s "$STDOUT_FILE")B"
