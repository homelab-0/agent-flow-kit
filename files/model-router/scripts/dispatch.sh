#!/usr/bin/env bash
# dispatch.sh — launch ONE Orca-visible worker attempt for one story, under the
# immutable ExecutionStamp that the central agent-router already decided.
#
# THIS SCRIPT CHOOSES NOTHING. POST /v1/route is the sole routing authority on
# this path. dispatch.sh reads a closed, already-accepted ExecutionStamp,
# obtains fresh placement evidence when the stamp demands it, submits both to
# agent-stamp-validate, and only then launches the harness the stamp names.
# There is no fallback chain, no rate-limit re-route, and no runtime mutation of
# harness/model/effort — a different route requires a NEW /v1/route call and a
# NEW stamp (ExecutionProfile invariant 2, planning-time immutability).
#
# Usage:   dispatch.sh <story.md> [cycle]
# Deps:    yq (mikefarah v4+), jq, curl, orca, agent-stamp-validate,
#          plus the harness binary the stamp names (claude | codex).
#
# Exit codes. 0-3 are this script's original contract and keep their meaning.
# agent-stamp-validate's own 0/1/2 would collide with them, so they are REMAPPED
# into the 4/5 band before they ever reach a caller:
#   0  done — the worker finished and every gate passed
#   1  the worker finished but a gate failed (re-dispatch next cycle with notes)
#   2  spawn/config error (bad story, missing dep, missing persona, empty gates)
#   3  the worker is blocked and needs a human (NEEDS-HUMAN marker)
#   4  REFUSED — stamp well-formed but policy-INVALID   (validator exit 1)
#   5  REFUSED — stamp/catalog malformed, or the validator could not run
#      (validator exit 2). Never downgraded to "probably fine".
#   6  REFUSED — the stamp requires placement and fresh evidence could not be
#      obtained from POST /v1/place
#   7  REFUSED — NEEDS HUMAN: the stamp is valid, but this adapter implements no
#      validated launch contract for the stamped {harness, model_profile} pair.
#      Writes a ${STORY}.blocked marker naming the pair. The route is never
#      mutated and no substitute harness is ever chosen.
#   8  REFUSED — STORY SIZING: the pre-dispatch payload estimate is already at or
#      past the declared continuation threshold, so the worker could not finish
#      what it was given. Writes a ${STORY}.blocked marker typed STORY-SIZING:.
#      A planning outcome, not a routing one: nothing is placed, launched or
#      re-routed, and the estimate never reaches /v1/route.
#
# Billing invariants. Two funding shapes, both non-metered: the native vendor
# subscription sessions, and the gateway-backed local class on `claude`
# (cost_class free, no entitlement pool, a LAN-scoped agentgateway key that buys
# no vendor spend). The harness launch is sanitized per
# contracts/agent-router/HARNESS-LAUNCH-{claude,codex}.md — never add --bare,
# --full-auto, --dangerously-* or an API-key variable here. ANTHROPIC_API_KEY is
# set on no path: the gateway class authenticates with ANTHROPIC_AUTH_TOKEN, the
# bearer header the catalog validated, and never an API key.

set -euo pipefail

readonly EX_DONE=0
readonly EX_GATES_FAILED=1
readonly EX_CONFIG=2
readonly EX_NEEDS_HUMAN=3
readonly EX_STAMP_INVALID=4
readonly EX_STAMP_UNCHECKABLE=5
readonly EX_PLACEMENT=6
readonly EX_UNSUPPORTED_LAUNCH=7
readonly EX_SIZING_REFUSED=8

# The closed effort set. Taken from execution-stamp.schema.json, NOT from a
# harness CLI's accepted set: `claude --effort` also accepts `max`, but no
# catalog effort maps to it, so a stamp can never legitimately carry it.
readonly STAMP_EFFORTS="low medium high xhigh"

log()  { printf 'dispatch: %s\n' "$*" >&2; }
die()  { log "$1"; exit "${2:-$EX_CONFIG}"; }

# ---------------------------------------------------------------------------
# Pure helpers (unit-tested by tests/; no I/O, no globals)
# ---------------------------------------------------------------------------

# sha256_of / passwd_home — BSD+GNU portable (the kit runs on Linux and macOS).
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
passwd_home() {
  local u; u="$(id -un)"
  if command -v getent >/dev/null; then getent passwd "$u" | cut -d: -f6
  else dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}'; fi
}

# shq — encode a launcher-resolved value as a shell-safe LITERAL for embedding
# in generated terminal command text. This is what lets the launcher put its own
# control values into a command string without ever making task-shaped content
# shell source (HARNESS-LAUNCH-claude.md §5, "the invariant").
shq() { printf '%q' "$1"; }

# effort_is_stampable — fail-closed effort validation, run BEFORE launch.
# `claude --effort` FAILS OPEN: an unknown value warns on stderr, silently runs
# at the default effort and exits 0, and the effective effort is unobservable
# afterwards (HARNESS-LAUNCH-claude.md §4). Codex must not collapse xhigh onto
# high either — the frozen mapping is one-to-one (HARNESS-LAUNCH-codex.md §4).
effort_is_stampable() {
  local e="${1:-}"
  [[ -n "$e" ]] || return 1
  case " $STAMP_EFFORTS " in *" $e "*) return 0 ;; *) return 1 ;; esac
}

# remap_validator_exit — translate agent-stamp-validate's 0/1/2 into this
# script's contract so the two exit vocabularies can never be confused.
remap_validator_exit() {
  case "${1:-}" in
    0) printf '%s' "$EX_DONE" ;;
    1) printf '%s' "$EX_STAMP_INVALID" ;;
    *) printf '%s' "$EX_STAMP_UNCHECKABLE" ;;
  esac
}

# native_model_arg — strip the provider qualifier at the CLI boundary only.
# `-m/--model` names a model, not a provider-qualified id; the qualified form
# stays the authoritative catalog data (HARNESS-LAUNCH-*.md §4).
native_model_arg() { printf '%s' "${1##*/}"; }

# build_claude_command — the frozen claude launch, as generated terminal text.
# Every launcher-owned value below is resolved and validated BEFORE this runs
# and is baked in as a shell-safe literal. None of them is a runtime lookup:
# an ambient $HOME/$PATH/$USER would reintroduce exactly the inherited-state
# dependency `env -i` exists to remove. The only runtime read is the prompt
# file, which is the sanctioned data channel for task/persona content.
build_claude_command() {
  local home="$1" path="$2" user="$3" prompt_file="$4" model="$5" effort="$6" \
        result_file="$7" persona_file="${8:-}"
  local persona_arg=""
  [[ -n "$persona_file" ]] && persona_arg=" --append-system-prompt-file $(shq "$persona_file")"
  printf '%s' \
"env -i HOME=$(shq "$home") PATH=$(shq "$path") USER=$(shq "$user") LANG=C.UTF-8 TERM=dumb \
claude -p \"\$(cat -- $(shq "$prompt_file"))\" \
--model $(shq "$model") --effort $(shq "$effort")${persona_arg} \
--permission-mode acceptEdits --tools \"Read,Glob,Grep,Write\" \
--strict-mcp-config --output-format json < /dev/null > $(shq "$result_file"); \
echo \"CLAUDE_EXIT=\$?\""
}

# build_claude_gateway_command — the SECOND validated claude launch class, as
# generated terminal text: gateway-backed local execution of a `hosting: local`
# profile, exactly as catalog 1.6.0 records it for local-code-standard
# (STORY-036-1, R1-R17). Everything the native launch freezes is preserved:
# the env -i allowlist sanitizer, the prompt file as the only data channel, the
# model and effort flags, acceptEdits, the four-tool set, --strict-mcp-config,
# the stdin redirect, the result-file redirect and the in-band exit line. The
# only difference is five per-process variables inside that allowlist.
#
# Four of the five are launcher-resolved literals, baked in exactly like HOME
# and PATH. The credential is the one value that must not be: the text carries
# only the 1Password REFERENCE and the service-account env file, and the value
# is resolved at terminal runtime, inside a command substitution, so it exists
# in no command text, no terminal title, no log and no file. Sourcing the env
# file inside that substitution also keeps the service-account token in a
# subshell rather than in the terminal's own environment.
#
# The text opens with `set +x` because the credential is assigned to a shell
# variable before `env -i`, and an xtrace inherited from the terminal's own
# shell (a `set -x` in a login rc, or a BASH_ENV) would render the resolved
# value into the persisted terminal buffer. Disabling xtrace for this command
# closes that channel; the native class assigns nothing and is unchanged.
#
# An empty read is fatal BEFORE claude starts. A claude with an empty token is
# not a degraded gateway session; it is an unauthenticated one, and starting it
# would put a session's provider and funding back in doubt — which is the whole
# thing this class exists to keep certain. It exits without printing an exit
# marker, so the launcher reports a launch that did not complete honestly
# rather than a run whose gates happened to pass.
build_claude_gateway_command() {
  local home="$1" path="$2" user="$3" prompt_file="$4" model="$5" effort="$6" \
        result_file="$7" persona_file="$8" base_url="$9" token_ref="${10}" \
        op_env_file="${11}" placement_header="${12}" max_context="${13}"
  local persona_arg=""
  [[ -n "$persona_file" ]] && persona_arg=" --append-system-prompt-file $(shq "$persona_file")"
  printf '%s' \
"set +x; \
ANTHROPIC_AUTH_TOKEN=\"\$(. $(shq "$op_env_file") && op read $(shq "$token_ref"))\"; \
[ -n \"\$ANTHROPIC_AUTH_TOKEN\" ] || { \
echo 'dispatch: gateway credential resolved EMPTY; refusing to start claude unauthenticated' >&2; \
exit 78; }; \
env -i HOME=$(shq "$home") PATH=$(shq "$path") USER=$(shq "$user") LANG=C.UTF-8 TERM=dumb \
ANTHROPIC_BASE_URL=$(shq "$base_url") ANTHROPIC_AUTH_TOKEN=\"\$ANTHROPIC_AUTH_TOKEN\" \
ANTHROPIC_MODEL=$(shq "$model") \
ANTHROPIC_CUSTOM_HEADERS=$(shq "x-placement: $placement_header") \
CLAUDE_CODE_MAX_CONTEXT_TOKENS=$(shq "$max_context") \
claude -p \"\$(cat -- $(shq "$prompt_file"))\" \
--model $(shq "$model") --effort $(shq "$effort")${persona_arg} \
--permission-mode acceptEdits --tools \"Read,Glob,Grep,Write\" \
--strict-mcp-config --output-format json < /dev/null > $(shq "$result_file"); \
echo \"CLAUDE_EXIT=\$?\"; unset ANTHROPIC_AUTH_TOKEN"
}

# build_codex_command — the frozen codex launch, as generated terminal text.
# Denylist sanitization is what the codex contract froze (§7); ANTHROPIC_API_KEY
# is unset too, on top of the contract's pair, so a codex launch can never leave
# a Claude API key reachable either.
# The task travels through the prompt file rather than being interpolated into
# the command, which is stricter than the codex contract's `"<task>"` sketch and
# matches the claude contract's data/shell-source invariant.
build_codex_command() {
  local prompt_file="$1" model="$2" effort="$3"
  printf '%s' \
"env -u OPENAI_API_KEY -u CODEX_API_KEY -u ANTHROPIC_API_KEY \
codex exec --model $(shq "$model") -c model_reasoning_effort=$(shq "$effort") \
-s workspace-write \"\$(cat -- $(shq "$prompt_file"))\"; \
echo \"CODEX_EXIT=\$?\""
}

# ---------------------------------------------------------------------------
# Context budget — the pure half (FR-96..99, lane A).
#
# Everything below is arithmetic and string work over values the CALLER already
# obtained from the trusted catalog and the declared policy file. Nothing here
# reads a threshold, invents a window or knows what a CLI is: NFR-13 keeps the
# budget model harness-agnostic, and the only reason these are functions at all
# is that a boundary that cannot be exercised without a launch is a boundary
# nobody has actually tested.
# ---------------------------------------------------------------------------

# budget_estimate_tokens — planned payload BYTES to an estimated token count,
# by the declared method id. An unknown id is a refusal, never a guess: an
# estimate whose method nobody declared is a number with no meaning attached.
#   bytes4-v1   ceil(bytes / 4)
budget_estimate_tokens() { # <bytes> <method-id>
  local bytes="${1:-}" method="${2:-}"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 1
  case "$method" in
    bytes4-v1) printf '%s' $(( (bytes + 3) / 4 )) ;;
    *) return 1 ;;
  esac
}

# budget_ratio_ppm — the estimate/window ratio in PARTS PER MILLION, as an
# integer. Ratios are compared and reported from this one value so that the
# comparison and the number a human reads can never disagree, and so that a
# boundary case lands exactly: bash has no floats, and doing this in awk would
# put the whole threshold decision on IEEE rounding.
budget_ratio_ppm() { # <estimate-tokens> <window-tokens>
  local est="${1:-}" win="${2:-}"
  [[ "$est" =~ ^[0-9]+$ && "$win" =~ ^[0-9]+$ ]] || return 1
  (( win > 0 )) || return 1
  printf '%s' $(( est * 1000000 / win ))
}

# budget_threshold_ppm — a declared decimal ratio ("0.85") as parts per million.
# Parsed by hand rather than with awk for the same reason: 0.85 is not
# representable in binary, and `0.85 * 1000000` can land on 849999.
budget_threshold_ppm() { # <decimal ratio>
  local r="${1:-}" whole frac
  [[ "$r" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  whole="${r%%.*}"
  frac="${r#"$whole"}"; frac="${frac#.}"
  frac="${frac}000000"; frac="${frac:0:6}"
  printf '%s' $(( 10#$whole * 1000000 + 10#$frac ))
}

# budget_crosses — does an observed ratio reach a threshold? A ratio EQUAL to a
# threshold COUNTS AS CROSSING IT (FR-98: "at or above"). Both arguments are
# already integers in parts per million, so this is exact at the boundary.
budget_crosses() { # <ratio-ppm> <threshold-ppm>
  local r="${1:-}" t="${2:-}"
  [[ "$r" =~ ^[0-9]+$ && "$t" =~ ^[0-9]+$ ]] || return 1
  (( r >= t ))
}

# budget_ratio_decimal — parts per million rendered as the fixed six-decimal
# number the thin result carries. Same source value as the comparison.
budget_ratio_decimal() { # <ratio-ppm>
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  printf '%d.%06d' $(( p / 1000000 )) $(( p % 1000000 ))
}

# ---------------------------------------------------------------------------
# Launcher configuration. Trusted policy material is ALWAYS launcher/installer
# configuration — an env var or the config file — and NEVER read from the story
# or the stamp. A workload cannot choose its own policy authority.
# ---------------------------------------------------------------------------

cfg() {  # cfg <yq-path> <ENV_OVERRIDE_NAME|""> [default]
  local from_env=""
  [[ -n "${2:-}" ]] && from_env="${!2:-}"
  if [[ -n "$from_env" ]]; then printf '%s' "$from_env"; return 0; fi
  local v=""
  if [[ -f "$CONFIG_FILE" ]]; then
    v="$(yq -r "$1 // \"\"" "$CONFIG_FILE" 2>/dev/null || true)"
  fi
  [[ "$v" == "null" ]] && v=""
  printf '%s' "${v:-${3:-}}"
}

# ---------------------------------------------------------------------------
# Orca: the ADE owns worktrees, terminals, processes and native auth.
# ---------------------------------------------------------------------------

orca_json() { orca "$@" --json 2>/dev/null; }

# orca_worktree_selector — the launch must be VISIBLE in Orca. If this process
# is not inside an Orca-managed worktree there is no worktree card and no
# terminal tab to watch, so the launch fails closed rather than going invisible.
# Worktree CREATION stays with Orca and the planning session (SKILL.md step 6):
# the story file has to already live inside the worktree for the sandboxed
# worker to read it at all.
orca_worktree_selector() {
  local here="$1" sel
  sel="$(orca_json worktree list \
        | jq -r --arg p "$here" '.result.worktrees[]? | select(.path == $p) | .id' \
        | head -1)"
  printf '%s' "$sel"
}

# orca_setup_policy_gate — HARNESS-LAUNCH §5 step 0. A repository that waits for
# setup makes the two-step (worktree, then custom-argv terminal) path unsafe,
# and stopping after the terminal exists is already too late.
# Only the policy field is extracted: the raw repo object embeds a live access
# token in gitRemoteIdentity.remoteUrl, so it must never reach a log, a terminal
# buffer or a file (HARNESS-LAUNCH-claude.md §3).
orca_setup_policy_gate() {
  local repo_id="$1" policy
  policy="$(orca_json repo list \
           | jq -r --arg id "$repo_id" \
               '.result.repos[]? | select(.id == $id) | .hookSettings.setupAgentStartupPolicy // ""' \
           | head -1)"
  [[ -n "$policy" ]] || die "could not read the repo setup policy for $repo_id — refusing to launch blind" "$EX_CONFIG"
  [[ "$policy" == "start-immediately" ]] || \
    die "repo setup policy is '$policy', not 'start-immediately' — this launch path cannot preserve setup ordering. STOP." "$EX_CONFIG"
  log "setup policy: $policy"
}

# orca_launch — create the terminal, then harvest the in-band exit line.
# `orca terminal wait --for exit` does NOT fire: the terminal outlives its
# command, so the "<HARNESS>_EXIT=" line is the only reliable completion signal
# (both harness contracts §8). The echoed command line itself contains a literal
# `$?`, so anchoring on a digit run cannot mistake it for the real result.
orca_launch() {
  local selector="$1" title="$2" command_text="$3" exit_marker="$4" timeout_s="$5"
  local handle deadline raw status line

  handle="$(orca_json terminal create --worktree "id:$selector" --title "$title" \
            --command "$command_text" | jq -r '.result.terminal.handle // ""')"
  [[ -n "$handle" ]] || die "orca terminal create returned no handle" "$EX_CONFIG"
  TERMINAL_HANDLE="$handle"
  log "launched in Orca terminal $handle — \"$title\""

  deadline=$(( $(date +%s) + timeout_s ))
  while :; do
    raw="$(orca_json terminal read --terminal "$handle" --limit 5000 || true)"
    TERMINAL_TAIL="$(jq -r '.result.terminal.tail[]? // ""' <<<"$raw" 2>/dev/null || true)"
    line="$(grep -aoE "^${exit_marker}=[0-9]+$" <<<"$TERMINAL_TAIL" | tail -1 || true)"
    if [[ -n "$line" ]]; then
      HARNESS_EXIT="${line##*=}"
      log "$exit_marker=$HARNESS_EXIT"
      return 0
    fi
    status="$(jq -r '.result.terminal.status // ""' <<<"$raw" 2>/dev/null || true)"
    if [[ "$status" == "exited" || "$status" == "closed" ]]; then
      die "terminal $handle ended without an $exit_marker line — the launch did not complete honestly" "$EX_CONFIG"
    fi
    (( $(date +%s) < deadline )) || \
      die "no $exit_marker line after ${timeout_s}s — giving up rather than guessing the outcome" "$EX_CONFIG"
    sleep 5
  done
}

# ---------------------------------------------------------------------------
# Placement — ephemeral, per-attempt, never cached across cycles.
# ---------------------------------------------------------------------------

# place_if_required — fetch fresh PlacementEvidence when, and only when, the
# stamp says placement_required. When it is false, evidence must be ABSENT:
# supplying it is itself a validation failure (vendor_profile_with_placement).
#
# ORDERING NOTE (deliberate, see the story return): this runs BEFORE
# validate_stamp because agent-stamp-validate CONSUMES the evidence as an input
# (--evidence). Placing after validation would fail the placement rule with
# placement_evidence_missing by construction. The "late-bound" requirement is
# about freshness, and it is fully preserved: the /v1/place call happens per
# launch attempt, immediately before validation, which is immediately before
# launch, and the result is never reused across cycles.
place_if_required() {
  local required="$1" profile="$2" policy="$3" out="$4"
  if [[ "$required" != "true" ]]; then
    log "placement: not required for $profile (vendor-hosted) — no /v1/place call, no evidence"
    return 0
  fi
  [[ -n "$ROUTER_URL" ]] || die "placement required but no router endpoint configured" "$EX_PLACEMENT"
  local token="${!CALLER_TOKEN_ENV:-}"
  [[ -n "$token" ]] || die "placement required but \$$CALLER_TOKEN_ENV is empty — the caller token is never stored in config" "$EX_PLACEMENT"

  local resolved_at body http
  resolved_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  body="$(mktemp)"; TMPFILES+=("$body")
  http="$(curl -sS -o "$body" -w '%{http_code}' -X POST "$ROUTER_URL/v1/place" \
          -H "Authorization: Bearer $token" \
          -H 'Content-Type: application/json' \
          --max-time 20 \
          -d "$(jq -nc --arg p "$profile" --arg pol "$policy" \
                '{model_profile:$p, placement_policy:$pol}')" || true)"
  [[ "$http" == "200" ]] || \
    die "POST /v1/place returned HTTP ${http:-000} — refusing to launch without a placement" "$EX_PLACEMENT"
  jq -r '.status // ""' "$body" | grep -qx 'placed' || \
    die "POST /v1/place did not return status=placed — refusing to launch" "$EX_PLACEMENT"

  # PlacementEvidence carries EXACTLY two members, and the PlaceResult is nested
  # UNMODIFIED: there is one authoritative copy of placement data, so nothing
  # from the result is restated at this level.
  jq -n --arg t "$resolved_at" --slurpfile r "$body" \
     '{resolved_at:$t, result:$r[0]}' > "$out"
  log "placement: $(jq -r '.result.placement // "?"' "$out") (ttl $(jq -r '.result.ttl_seconds // "?"' "$out")s, resolved $resolved_at)"
}

# ---------------------------------------------------------------------------
# Final validation — fail-closed, immediately before launch.
# ---------------------------------------------------------------------------

validate_stamp() {
  local stamp="$1" evidence="$2" verdict_out="$3"
  local args=(--catalog "$CATALOG_PATH" --stamp "$stamp")
  [[ -n "$evidence" && -s "$evidence" ]] && args+=(--evidence "$evidence")

  local rc=0
  "$VALIDATOR" "${args[@]}" >"$verdict_out" 2>"$verdict_out.err" || rc=$?
  local mapped; mapped="$(remap_validator_exit "$rc")"
  if (( mapped != EX_DONE )); then
    log "STAMP VALIDATION REFUSED THE LAUNCH (validator exit $rc -> dispatch exit $mapped)"
    if (( rc == 1 )); then
      jq -r '.checks[]? | select(.passed == false) | "  FAILED \(.name): \(.reason_code) — \(.message)"' \
        "$verdict_out" >&2 2>/dev/null || true
    else
      sed 's/^/  /' "$verdict_out.err" >&2 2>/dev/null || true
    fi
    exit "$mapped"
  fi
  log "stamp valid — all 8 checks passed (catalog $(jq -r '.catalog_version // "?"' "$verdict_out"))"
}

# ---------------------------------------------------------------------------
# Launch-contract capability guard
#
# THIS IS NOT A SECOND ROUTING AUTHORITY, and the distinction is the whole point.
# The adapter does not judge the route, does not score profiles, and has no
# opinion about what the catalog ought to approve. It answers the one question
# only it can answer: "do I have a VALIDATED way to launch this?" A launcher
# that improvises a launch it has never validated is exactly what every frozen
# contract in this chain exists to prevent.
#
# The launch classes this adapter implements, whose contracts are
# live-validated and frozen:
#   1. NATIVE VENDOR SUBSCRIPTION, claude -> HARNESS-LAUNCH-claude.md and
#      codex -> HARNESS-LAUNCH-codex.md. Vendor-hosted (§9: placement_required
#      is false), and §7 FORBIDS every endpoint, base-URL, provider and model
#      redirection mechanism the CLI exposes.
#   2. GATEWAY-BACKED LOCAL, claude only -> catalog 1.6.0,
#      profiles.local-code-standard.notes, which IS the validated launch
#      contract for that pair (STORY-036-1, R1-R17). A `hosting: local` profile
#      reached through agentgateway's Anthropic-compatible endpoint, pinned to
#      the catalog's physical model, placed by the x-placement header copied
#      verbatim from the /v1/place evidence, funded by a LAN-scoped gateway key
#      that buys no vendor spend. The four redirection variables it sets are a
#      PER-PROCESS exception this catalog validated; a file-borne redirection
#      would be an unvalidated second path and the settings preflight still
#      refuses one.
#
# The discriminator is derived from the STAMP plus the launcher's TRUSTED
# CATALOG, belt and braces, and never from the story or a runtime lookup:
#   class 1 iff the stamped model_profile is in that vendor's native family AND
#           the stamped entitlement_pool is that vendor's native subscription
#           pool (claude -> claude/* on anthropic-max, codex -> openai/* on
#           openai-plus) AND placement_required is not true;
#   class 2 iff the harness is claude AND the trusted catalog marks the profile
#           hosting: local AND placement_required is true AND the stamp carries
#           NO entitlement pool AND its cost_class is free.
# Everything else is refused, whatever its placement flag says.
#
# Two instances of what class 2 is NOT, and why the discriminator is this
# specific rather than keyed on placement_required alone:
#   1. {claude, minimax/strong} (catalog 1.5.0): vendor-hosted, so
#      placement_required is false and the old placement-keyed guard waved it
#      through - yet the catalog's own notes say it is reachable ONLY via an
#      ANTHROPIC_BASE_URL redirection nothing here has validated. The native
#      launch then stripped 'minimax/m3' to 'm3' and ran it against Anthropic on
#      the anthropic-max subscription while every artifact recorded minimax: a
#      silent provider AND funding provenance mismatch from a clean stamp.
#   2. A local profile stamped with a vendor entitlement pool: class 2 is free
#      by construction, so a pool on that stamp means the funding story and the
#      execution story disagree, and neither class covers it.
# An approved pair is still NOT permission to invent a launch path - a pair can
# be routable and simultaneously unlaunchable, and the honest response is to
# stop and say so. What changed is that {claude, local} now HAS a validated
# path; what did not change is that having one is the only thing that admits it.
# ---------------------------------------------------------------------------

# unsupported_launch_reason - echoes a human-readable reason when this adapter
# has no validated launch contract for the stamped pair, or nothing when it
# does. The stamp supplies harness, profile, placement flag, entitlement pool
# and cost class; the launcher's TRUSTED catalog supplies the profile hosting.
# Neither the story nor the environment is consulted, and an argument that was
# not supplied fails the pair CLOSED rather than defaulting it open.
unsupported_launch_reason() {
  local harness="$1" profile="$2" placement_required="$3" pool="$4" \
        hosting="${5:-}" cost_class="${6:-}"
  local native_family native_pool family_ok=""
  case "$harness" in
    claude)
      native_family="claude/*"; native_pool="anthropic-max"
      case "$profile" in claude/*) family_ok=1 ;; esac
      ;;
    codex)
      native_family="openai/*"; native_pool="openai-plus"
      case "$profile" in openai/*) family_ok=1 ;; esac
      ;;
    *)
      # Unknown harnesses are refused later by the launch case; this guard
      # only declares capability for the contracts it implements.
      return 0
      ;;
  esac

  # Class 1 - native vendor subscription. Unchanged, and deliberately checked
  # first so nothing about the second class can widen it.
  if [[ -n "$family_ok" && "$pool" == "$native_pool" && "$placement_required" != "true" ]]; then
    return 0
  fi

  # Class 2 - gateway-backed local execution. claude only, and every condition
  # is required: each one is a fact the catalog's launch contract assumes.
  if [[ "$harness" == "claude" && "$placement_required" == "true" ]]; then
    local missing=""
    if [[ "$hosting" != "local" ]]; then
      missing="the trusted catalog does not mark profile '$profile' hosting: local (it reads '${hosting:-<unset>}')"
    fi
    if [[ -n "$pool" && "$pool" != "null" ]]; then
      if [[ -n "$missing" ]]; then missing+="; and "; fi
      missing+="the stamp carries entitlement_pool '$pool', while gateway-backed local execution draws on no pool at all"
    fi
    if [[ "$cost_class" != "free" ]]; then
      if [[ -n "$missing" ]]; then missing+="; and "; fi
      missing+="the stamp's cost_class is '${cost_class:-<unset>}', not 'free'"
    fi
    if [[ -z "$missing" ]]; then
      return 0   # gateway-backed local: validated, launchable
    fi
    printf '%s' "harness 'claude' has two validated launch classes: NATIVE VENDOR SUBSCRIPTION execution (vendor-hosted, placement_required false, profile family '$native_family' funded by entitlement_pool '$native_pool'), and GATEWAY-BACKED LOCAL execution (catalog hosting 'local', placement_required=true, no entitlement pool, cost_class 'free'). Profile '$profile' matches neither: $missing. Admitting it anyway would mean improvising a launch neither contract validated, and the only other mechanisms that would point 'claude' at that endpoint are the provider/base-URL redirections its native contract explicitly forbids."
    return 0
  fi

  # Local compute on a harness with NO gateway-backed class keeps the
  # established refusal wording; for codex it is still exactly true.
  if [[ "$placement_required" == "true" ]]; then
    printf '%s' "harness '$harness' has a validated launch contract for NATIVE VENDOR SUBSCRIPTION execution only (vendor-hosted, placement_required false). Profile '$profile' carries placement_required=true, i.e. local compute, which that contract cannot reach: the only mechanisms that would point '$harness' at a local endpoint are the provider/base-URL redirections its contract explicitly forbids."
    return 0
  fi

  # Vendor-hosted but not natively reachable: name the actual mismatch.
  local mismatch=""
  if [[ -z "$family_ok" ]]; then
    mismatch="model_profile '$profile' is outside the native family '$native_family'"
  fi
  if [[ "$pool" != "$native_pool" ]]; then
    if [[ -n "$mismatch" ]]; then mismatch+=", and "; fi
    mismatch+="entitlement_pool '${pool:-<none>}' is not the native pool '$native_pool'"
  fi
  printf '%s' "harness '$harness' has a validated launch contract for NATIVE VENDOR SUBSCRIPTION execution only: profile family '$native_family' funded by entitlement_pool '$native_pool'. Stamped ${mismatch}. The only mechanisms that would point '$harness' at that provider are the provider/base-URL redirections its contract explicitly forbids; a native launch would instead strip the provider qualifier and silently run the wrong provider on the wrong funding pool while the stamp and every downstream artifact record otherwise."
}

# refuse_unsupported_launch - write the .blocked marker a human will read.
refuse_unsupported_launch() {
  local harness="$1" profile="$2" effort="$3" reason="$4" marker="$5"
  rm -f "$marker"
  cat > "$marker" <<EOF
UNSUPPORTED-LAUNCH-CONTRACT: harness=${harness} model_profile=${profile} effort=${effort}

${reason}

The stamp is VALID: the router approved this pair and agent-stamp-validate
passed it. What is missing is a validated launch contract on THIS side, so the
refusal is the launch adapter declaring its own capability - not a second
opinion about the route.

The route was NOT modified. No substitute harness, model or effort was chosen,
and no fallback exists to choose one. A launcher that silently retargeted this
attempt would be making a routing decision after acceptance, with no stamp, no
expiry and no validation - the exact failure this chain exists to prevent.

What a human can do:
  - re-route: POST /v1/route for a pair this adapter has a validated launch
    class for - the harness vendor's own profile family on its own entitlement
    pool, or a hosting: local profile on claude, placement-required, free and
    drawing on no entitlement pool - accept it, re-stamp
    (scripts/make-stamp.sh), and re-dispatch; or
  - fix the mismatch the reason above names, if it is a stamp or catalog fact
    that is simply wrong; or
  - wait for a harness/profile pair to gain its own validated launch contract,
    after which it becomes launchable with no change here.
EOF
}

# ---------------------------------------------------------------------------
# Context budget — the half that touches the filesystem.
#
# The policy document is LAUNCHER configuration and is loaded like all the
# rest: config file or env override, never the story and never the stamp. The
# window is the trusted catalog's, read exactly. Between them they are the only
# two authorities this section has, and it invents neither.
# ---------------------------------------------------------------------------

# budget_policy_missing_keys — which required policy keys this file does not
# declare, space-separated and empty when it declares them all. A MISSING
# THRESHOLD IS NOT A DEFAULT: the caller refuses on any output at all, so no
# threshold is ever reachable except from the policy document.
budget_policy_missing_keys() { # <policy-file>
  local f="${1:-}" k v missing=""
  [[ -f "$f" && -r "$f" ]] || { printf '%s' "unreadable"; return 0; }
  yq -e . "$f" >/dev/null 2>&1 || { printf '%s' "unparseable"; return 0; }
  for k in estimate_method sizing_risk_ratio checkpoint_ratio continuation_ratio \
           continuation_cap; do
    v="$(yq -r ".$k // \"\"" "$f" 2>/dev/null || true)"
    [[ -z "$v" || "$v" == "null" ]] && missing+="${missing:+ }$k"
  done
  v="$(yq -r '.budget_states // [] | length' "$f" 2>/dev/null || true)"
  [[ "$v" == "4" ]] || missing+="${missing:+ }budget_states"
  v="$(yq -r '.reason_codes // [] | length' "$f" 2>/dev/null || true)"
  [[ "${v:-0}" -ge 5 ]] 2>/dev/null || missing+="${missing:+ }reason_codes"
  printf '%s' "$missing"
}

# load_budget_policy — read the declared policy into BUDGET_* globals, or
# refuse. Called EARLY, before any placement, terminal or artifact exists: a
# host whose budget policy cannot be read has no thresholds, and dispatching
# anyway would mean running unbudgeted work while reporting budget health.
load_budget_policy() { # <policy-file>
  local f="$1" missing
  missing="$(budget_policy_missing_keys "$f")"
  [[ -z "$missing" ]] || \
    die "BUDGET_POLICY_UNREADABLE: the context-budget policy '$f' is unusable ($missing). Thresholds and the estimate method live ONLY in that document — there is no default in code, so a policy that cannot be read in full refuses dispatch rather than running unbudgeted work." "$EX_CONFIG"

  BUDGET_POLICY_FILE="$f"
  BUDGET_METHOD="$(yq -r '.estimate_method' "$f")"
  BUDGET_RISK_PPM="$(budget_threshold_ppm "$(yq -r '.sizing_risk_ratio' "$f")")" || \
    die "BUDGET_POLICY_UNREADABLE: sizing_risk_ratio in '$f' is not a decimal ratio" "$EX_CONFIG"
  BUDGET_CONTINUATION_PPM="$(budget_threshold_ppm "$(yq -r '.continuation_ratio' "$f")")" || \
    die "BUDGET_POLICY_UNREADABLE: continuation_ratio in '$f' is not a decimal ratio" "$EX_CONFIG"
  BUDGET_CHECKPOINT_PPM="$(budget_threshold_ppm "$(yq -r '.checkpoint_ratio' "$f")")" || \
    die "BUDGET_POLICY_UNREADABLE: checkpoint_ratio in '$f' is not a decimal ratio" "$EX_CONFIG"
  log "budget policy: $f (method $BUDGET_METHOD, risk $(budget_ratio_decimal "$BUDGET_RISK_PPM"), checkpoint $(budget_ratio_decimal "$BUDGET_CHECKPOINT_PPM"), continuation $(budget_ratio_decimal "$BUDGET_CONTINUATION_PPM"))"
}

# budget_payload_paths — the payload the worker is planned to receive, in the
# declared order and each path exactly once: the persona file when one is
# stamped, the story file, the generated prompt file, then every path declared
# under the story's optional `payload_refs:` frontmatter key. The enumeration is
# the contract (FR-97) — it is printed into the refusal marker so a human sees
# what was counted, not just the total.
#
# payload_refs entries are REPO-RELATIVE, resolved against the worktree root
# that also bounds the worker's sandbox. One that does not resolve to a readable
# file INSIDE that root is PAYLOAD_REF_MISSING and refuses: an estimate that
# silently skipped part of the payload would under-report exactly when it
# matters, and one that counted a file outside the sandbox would report a
# payload the worker cannot actually read. Containment is checked with the same
# rule main() applies to the story itself, so `../shared/template.md` refuses
# for the same reason a story outside the worktree does — `-f` and `-r` alone
# are satisfied by any readable file on the host.
budget_payload_paths() { # -> one absolute path per line, deduplicated
  local seen=() declared=() p rp ref
  [[ -n "${PERSONA_FILE:-}" ]] && declared+=("$PERSONA_FILE")
  declared+=("$STORY" "$PROMPT_FILE")
  for p in "${declared[@]}"; do
    rp="$(realpath "$p" 2>/dev/null || true)"
    [[ -n "$rp" && -f "$rp" ]] || continue
    case " ${seen[*]:-} " in *" $rp "*) continue ;; esac
    seen+=("$rp"); printf '%s\n' "$rp"
  done
  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    rp="$(realpath "$PWD/$ref" 2>/dev/null || true)"
    [[ -n "$rp" && -f "$rp" && -r "$rp" ]] || \
      die "PAYLOAD_REF_MISSING: the story declares payload_refs entry '$ref', which is not a readable file under $PWD. The sizing estimate counts every declared payload input or none — it never silently drops one." "$EX_CONFIG"
    case "$rp" in
      "$(realpath "$PWD")"/*) ;;
      *) die "PAYLOAD_REF_MISSING: the story declares payload_refs entry '$ref', which resolves to '$rp' — OUTSIDE the current directory ($PWD) that bounds the worker's sandbox. The sandboxed worker cannot read it, so counting it would size a payload the worker never receives." "$EX_CONFIG" ;;
    esac
    case " ${seen[*]:-} " in *" $rp "*) continue ;; esac
    seen+=("$rp"); printf '%s\n' "$rp"
  done < <(yq --front-matter=extract -r '.payload_refs[]?' "$STORY" 2>/dev/null || true)
}

# file_bytes — byte length, BSD+GNU portable. `wc -c` is used rather than stat
# so one code path serves both, and it counts bytes on every platform the kit
# runs on.
file_bytes() { wc -c < "$1" | tr -d ' '; }

# refuse_story_sizing — the marker a human reads when a story was too big to
# dispatch. It names the arithmetic and every input that produced it, because
# "too big" without the inputs is not a finding anyone can act on. Its first
# line carries the declared reason code SIZING_REFUSED, as does the dispatch
# log line for the refusal: a stable code that appears in no artifact leaves
# automation parsing an exit code or a marker prefix instead, which is the
# coupling the reason-code discipline exists to remove.
refuse_story_sizing() { # <marker> <estimate> <window> <ratio> <threshold> <inputs-table>
  local marker="$1" est="$2" win="$3" ratio="$4" threshold="$5" inputs="$6"
  rm -f "$marker"
  cat > "$marker" <<EOF
STORY-SIZING: reason=SIZING_REFUSED estimate=${est} window=${win} ratio=${ratio} threshold=${threshold} method=${BUDGET_METHOD}

The planned payload for this story is already at or past the declared
continuation threshold before a worker has read a single line of it. A payload
that starts past the point where a worker would have to stop and hand over
cannot complete the work, so dispatch is refused here rather than after a
terminal, a placement and a session have been spent proving it.

Inputs counted (each exactly once, by byte length):
${inputs}
Window: ${win} tokens, read exactly from the trusted catalog's min_context for
the routed profile. It is not derived, extended or substituted, and the estimate
was never sent to /v1/route: sizing is advisory kit policy and changes no route.

This is a PLANNING outcome, not a routing one. Nothing was placed, no terminal
was created, no command text was built, and this attempt wrote no result
artifact.

What a human can do:
  - split the story so each part's payload fits inside the routed window; or
  - reduce what the payload declares — the persona, the story body, or the
    payload_refs list; or
  - route the story to a profile whose catalog window is large enough, which
    means a NEW POST /v1/route call and a NEW stamp, never an edit to this one; or
  - change the declared threshold in ${BUDGET_POLICY_FILE}, which is a policy
    decision and belongs to whoever owns that policy.
EOF
}

# record_budget_line_unlocked — the append itself. Every caller reaches it
# through record_budget_line, which holds the story's lock for the whole of it.
# The CODE is what idempotence is keyed on alongside the cycle, so a cycle that
# produces both a sizing observation and a continuation records both once, and
# neither can suppress the other.
record_budget_line_unlocked() { # <story> <cycle> <code> <detail>
  local story="$1" cycle="$2" code="$3" detail="$4" line tmp
  line="- budget: ${code} ${detail} cycle ${cycle} $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if grep -qaE "^- budget: ${code} .* cycle ${cycle} " "$story"; then
    log "budget: ${code} already recorded for cycle ${cycle} — not duplicated"
    return 0
  fi
  if ! grep -qaE '^## Dev Agent Record[[:space:]]*$' "$story"; then
    printf '\n## Dev Agent Record\n\n%s\n' "$line" >> "$story"
    log "budget: ${code} recorded (Dev Agent Record heading created)"
    return 0
  fi
  tmp="$(mktemp)"; TMPFILES+=("$tmp")
  # Appended at the END of the Dev Agent Record section — after whatever the
  # section already holds and before the next heading — so the lines read in
  # cycle order instead of newest-first.
  awk -v line="$line" '
    /^## Dev Agent Record[[:space:]]*$/ { print; inrec = 1; next }
    inrec && /^## / { print line; print ""; inrec = 0; print; next }
    { print }
    END { if (inrec) print line }
  ' "$story" > "$tmp"
  cat "$tmp" > "$story"
  log "budget: ${code} recorded in $story"
}

# record_budget_line — append one budget observation to the story's own record,
# once per cycle. IDEMPOTENCE IS KEYED ON THE CYCLE, not on the whole line: a
# re-dispatch of the same cycle must not double-write, while a genuinely new
# cycle is a new observation and gets its own line. When the story has no
# Dev Agent Record heading the heading is created rather than the finding
# dropped — a finding nobody records is a finding nobody acts on.
#
# The whole read-modify-write is ONE critical section, held on a descriptor
# opened on the story itself. Without it two dispatches of the same story that
# reach the risk band together interleave: the cheap outcome is a lost finding,
# the real one is the loser rewriting the story from a copy it read before the
# winner's write — which under contention truncates the frontmatter and the
# body along with it. The lock is on the inode, and the write preserves the
# inode, so it covers the `cat` as well as the read.
#
# flock(1) is util-linux and is absent from a stock macOS, which the kit also
# runs on. There it degrades to the previous unserialised behaviour and says so
# rather than refusing to record the finding at all: a dispatch must not fail
# because a host lacks the tool that makes a concurrent dispatch safe.
record_budget_line() { # <story> <cycle> <code> <detail>
  local lk rc=0
  if ! command -v flock >/dev/null 2>&1; then
    log "budget: flock unavailable on this host — the story-record append runs unserialised"
    record_budget_line_unlocked "$@"
    return $?
  fi
  if ! exec {lk}<"$1"; then
    log "budget: cannot open $1 to lock it — the append runs unserialised"
    record_budget_line_unlocked "$@"
    return $?
  fi
  flock -x "$lk"
  record_budget_line_unlocked "$@" || rc=$?
  exec {lk}<&-
  return "$rc"
}

# ---------------------------------------------------------------------------
# Per-harness usage observation (FR-104, NFR-13/14, lane B).
#
# The kit NEVER scrapes a terminal or a transcript to reconstruct usage. Each
# approved harness gets a named adapter that reads only what that harness
# publishes, and the core calls one interface and one shape:
#   {usage_tokens, window_tokens, provenance, observed_at, reason}
# with the token members null when unobserved. An adapter that cannot observe
# usage says NOT_EVALUATED; that is an answer, never a fallback the core has to
# compensate for, and it never blocks the other harness.
usage_unobservable() { # <reason-code>
  jq -nc --arg r "$1" '{usage_tokens:null, window_tokens:null,
                        provenance:"NOT_EVALUATED", observed_at:null, reason:$r}'
}

# usage_adapter_claude — `claude -p --output-format json` writes ONE result
# envelope when the turn ends. Under the frozen launch text there is no
# stream-json, so mid-run usage does not exist to be read: the observation is
# END_OF_RUN or it is nothing, and it is labelled as such.
#
# usage_tokens is the context actually HELD at the last request — input, cache
# reads and cache creation summed. Output tokens are not context the next turn
# carries, so adding them would inflate the ratio against a window they never
# occupied. window_tokens is CORROBORATION ONLY: the budget window is the
# catalog's on every path, and a harness that reports a different number is
# recorded and left disagreeing, because reconciling two authorities by picking
# one is how a kit starts inventing routed facts.
usage_adapter_claude() { # <result-file> <native-model>
  local f="${1:-}" model="${2:-}" obs
  [[ -f "$f" ]] || { usage_unobservable USAGE_UNOBSERVABLE; return 0; }
  obs="$(jq -c --arg m "$model" '
      (.usage // {}) as $u
      | (($u.input_tokens // 0) + ($u.cache_read_input_tokens // 0)
         + ($u.cache_creation_input_tokens // 0)) as $t
      | (.modelUsage // {}) as $mu
      | (($mu[$m].contextWindow)
         // (if ($mu | length) == 1 then ($mu | to_entries[0].value.contextWindow) else null end)) as $w
      | if ($u | type) != "object" or ($u | length) == 0 or ($t | type) != "number"
        then null
        else {usage_tokens:$t, window_tokens:(if ($w | type) == "number" then $w else null end),
              provenance:"HARNESS_ENVELOPE", observed_at:"END_OF_RUN", reason:null}
        end' "$f" 2>/dev/null || true)"
  if [[ -z "$obs" || "$obs" == "null" ]]; then usage_unobservable USAGE_UNOBSERVABLE; return 0; fi
  printf '%s' "$obs"
}

# usage_adapter_codex — `codex exec` without --json emits no machine-readable
# usage at all under the frozen launch text, and the only other place the
# number exists is the terminal buffer, which FR-104 puts out of bounds. So the
# honest answer is the whole adapter.
usage_adapter_codex() { usage_unobservable USAGE_UNOBSERVABLE; }

# harness_usage_observation — the ONE interface the core calls. Adding a harness
# means adding an adapter and one case arm; nothing above this line changes.
harness_usage_observation() { # <harness> <result-file> <native-model>
  case "$1" in
    claude) usage_adapter_claude "${2:-}" "${3:-}" ;;
    codex)  usage_adapter_codex ;;
    *)      usage_unobservable USAGE_UNOBSERVABLE ;;
  esac
}

# budget_evaluate_usage — the post-run half of FR-99, on exactly the arithmetic
# lane A already froze for the pre-dispatch half: parts per million, and a ratio
# EQUAL to a threshold counts as crossing it. Sets the BUDGET_* globals the thin
# result carries. Nothing here knows what a CLI is.
budget_evaluate_usage() { # <observation-json> <catalog-window>
  local obs="$1" win="$2" tok rep ppm
  BUDGET_USAGE_TOKENS="$(jq -r '.usage_tokens // ""' <<<"$obs")"
  BUDGET_USAGE_PROVENANCE="$(jq -r '.provenance' <<<"$obs")"
  BUDGET_OBSERVED_AT="$(jq -r '.observed_at // ""' <<<"$obs")"
  BUDGET_USAGE_RATIO="" BUDGET_USAGE_REASON=""
  rep="$(jq -r '.window_tokens // ""' <<<"$obs")"
  BUDGET_WINDOW_REPORTED="$rep"
  tok="$BUDGET_USAGE_TOKENS"

  # A window the harness reports that disagrees with the routed one is a fact
  # about the two documents, recorded and left unresolved.
  if [[ -n "$rep" && -n "$win" && "$rep" != "$win" ]]; then
    BUDGET_FINDINGS+=("WINDOW_DISAGREEMENT")
    log "budget: harness reports window $rep, the CATALOG routes $win — recorded, not reconciled"
  fi

  # An unobservable usage does NOT overwrite the state the pre-dispatch half
  # reached. That state is a real verdict about a real estimate; replacing it
  # with NOT_EVALUATED would report LESS than the kit knows, and the honest
  # place for "no usage was observed" is the usage members themselves, which is
  # where a reader who cares about observation looks. The window is checked
  # first: without one, nothing could ever be evaluated whatever the harness
  # published, so that is the reason worth carrying.
  if [[ -z "$win" ]]; then
    BUDGET_USAGE_REASON="CONTEXT_WINDOW_UNDECLARED"
    log "budget: no catalog window, so observed usage cannot be evaluated"
    return 0
  fi
  if [[ -z "$tok" ]]; then
    BUDGET_USAGE_REASON="$(jq -r '.reason // "USAGE_UNOBSERVABLE"' <<<"$obs")"
    log "budget: usage $BUDGET_USAGE_REASON for harness $HARNESS — the pre-dispatch verdict stands"
    return 0
  fi
  ppm="$(budget_ratio_ppm "$tok" "$win")" || \
    die "budget: observed usage $tok could not be divided by window $win" "$EX_CONFIG"
  BUDGET_USAGE_RATIO="$(budget_ratio_decimal "$ppm")"
  if budget_crosses "$ppm" "$BUDGET_CONTINUATION_PPM"; then
    BUDGET_STATE="CONTINUATION_REQUIRED"; BUDGET_REASON=""
  elif budget_crosses "$ppm" "$BUDGET_CHECKPOINT_PPM"; then
    BUDGET_STATE="CHECKPOINT_DUE"; BUDGET_REASON=""
  else
    BUDGET_STATE="OK"; BUDGET_REASON=""
  fi
  # The PM's story-sizing signal (FR-105): a run that ENDED at or above the
  # checkpoint ratio was sized too close to its window, whatever it reported.
  budget_crosses "$ppm" "$BUDGET_CHECKPOINT_PPM" && BUDGET_FINDINGS+=("HIGH_USAGE")
  log "budget: usage $tok / window $win = $BUDGET_USAGE_RATIO -> $BUDGET_STATE (observed $BUDGET_OBSERVED_AT, $BUDGET_USAGE_PROVENANCE)"
  return 0
}

# ---------------------------------------------------------------------------
# Checkpoint and continuation artifacts (FR-100, FR-101).
# ---------------------------------------------------------------------------

# artifact_redact — the kit's redaction discipline at the ONE place artifact- or
# worker-derived text can reach a result, a log or a marker. Indirected through
# BUDGET_REDACT_FN like lib/afk-common.sh indirects its own, and assigned
# unconditionally so an exported value cannot select a bypass at runtime.
artifact_redact() { # <text>
  printf '%s' "$1" | sed -E 's/[A-Za-z0-9_./+-]{24,}/[REDACTED]/g'
}
BUDGET_REDACT_FN=artifact_redact

# artifact_verdict — validate one lifecycle artifact against its declared schema
# id and required members. The verdict vocabulary is CLOSED, and no fragment of
# the file's own content is ever part of it: a diagnostic quoting the offending
# value is exactly how a secret in a malformed artifact reaches a marker.
artifact_verdict() { # <path> <schema-id> <required members...>
  local f="$1" schema="$2"; shift 2
  [[ -f "$f" ]] || { printf 'ARTIFACT_MISSING'; return 1; }
  jq -e 'type == "object"' "$f" >/dev/null 2>&1 || { printf 'ARTIFACT_UNPARSEABLE'; return 1; }
  [[ "$(jq -r '.schema // ""' "$f" 2>/dev/null)" == "$schema" ]] || \
    { printf 'ARTIFACT_SCHEMA_MISMATCH'; return 1; }
  local m
  for m in "$@"; do
    jq -e --arg k "$m" 'has($k) and (.[$k] != null)' "$f" >/dev/null 2>&1 || \
      { printf 'ARTIFACT_MEMBER_MISSING'; return 1; }
  done
  printf 'VALID'; return 0
}

# artifact_identity_json — path plus content digest, nothing from inside the
# file: the members are for whoever resumes the story, not for the thin result.
artifact_identity_json() { # <path>
  jq -nc --arg p "$1" --arg s "sha256:$(sha256_of "$1")" '{path:$p, sha256:$s}'
}

# worker_discipline_paragraph — the launcher-owned phase-boundary contract, as
# DATA written into the prompt file, never as shell source. Mid-run usage is
# unobservable under the frozen launch texts, so the discipline cannot be
# usage-driven: it is deterministic policy the worker can follow without knowing
# its own usage, which is precisely FR-104's fallback. Byte-stable for a given
# story — no timestamp, no threshold, no observed number.
worker_discipline_paragraph() { # <story>
  local story="$1"
  cat <<EOF
Context discipline (launcher policy, not advice). Write or refresh the
checkpoint artifact ${story}.checkpoint.json at each of these declared phase
boundaries, regardless of how much context you think you have left: after you
have read the story; after implementation and before you run the gates; and
before you report. It is a JSON object with the members schema
("afk-checkpoint/1"), completed, current_state, remaining_acceptance,
next_steps and updated_at.
If you judge that you cannot finish this story, do not continue toward
exhaustion. Stop at the NEXT boundary, write ${story}.continuation.json — the
checkpoint members, with schema "afk-continuation/1", plus in_flight and
unretired_findings — then print one line
'CONTINUATION-REQUIRED: <one-line reason>' and end your turn.
Both artifacts are read by the kit and must be secret-free: record names,
paths and states, never credential values.
EOF
}

# ---------------------------------------------------------------------------
# Claude credential/settings preflight (HARNESS-LAUNCH-claude.md §3, §5.0b, §7)
# ---------------------------------------------------------------------------

# approved_path_has — is <binary> resolvable on the launcher's APPROVED PATH?
# The gateway credential is read by the terminal at launch time, so the tool
# that reads it has to be there BEFORE a terminal exists; checking the approved
# PATH rather than dispatch.sh's own keeps the answer about the environment the
# launch actually runs in. The subshell is what stops the probe PATH leaking.
approved_path_has() { # <binary> <PATH>
  ( PATH="$2"; command -v "$1" >/dev/null 2>&1 )
}

# resolve_approved_home — the supported store is Claude's DEFAULT store under
# the operator's explicitly resolved and approved HOME. Resolved and validated
# here, OUTSIDE the sanitized child environment, then embedded as a literal —
# never the ambient $HOME passed through blind, and never hard-coded.
resolve_approved_home() {
  local home
  home="$(cfg '.launcher.approved_home' AGENT_FLOW_APPROVED_HOME '')"
  [[ -z "$home" ]] && home="$(passwd_home)"
  [[ -n "$home" && -d "$home" ]] || die "could not resolve an approved HOME for the claude launch" "$EX_CONFIG"
  [[ -O "$home" ]] || die "approved HOME '$home' is not owned by the invoking user — refusing" "$EX_CONFIG"
  [[ -d "$home/.claude" ]] || die "approved HOME '$home' has no default .claude store — alternate/managed stores are unsupported by the frozen contract" "$EX_CONFIG"
  # CLAUDE_CONFIG_DIR is never propagated, and a non-default value here means
  # the operator is pointing at a store this contract never validated.
  if [[ -n "${CLAUDE_CONFIG_DIR:-}" && "${CLAUDE_CONFIG_DIR}" != "$home/.claude" ]]; then
    die "CLAUDE_CONFIG_DIR is set to a non-default store ('$CLAUDE_CONFIG_DIR') — unsupported by HARNESS-LAUNCH-claude.md §3; failing closed" "$EX_CONFIG"
  fi
  printf '%s' "$home"
}

# claude_settings_preflight — the env sanitizer cannot strip what lives in
# FILES. Refuse when any settings layer declares a credential helper, an env
# block, a forced login method or a provider/base-URL redirection.
claude_settings_preflight() {
  local home="$1" f hit
  for f in "$home/.claude/settings.json" \
           "$PWD/.claude/settings.json" \
           "$PWD/.claude/settings.local.json" \
           /etc/claude-code/managed-settings.json; do
    [[ -f "$f" ]] || continue
    hit="$(jq -r '[paths(scalars) as $p | $p[0]]
                  | map(select(. == "apiKeyHelper" or . == "env" or . == "awsAuthRefresh"
                               or . == "gcpAuthRefresh" or . == "forceLoginMethod"))
                  | unique | join(",")' "$f" 2>/dev/null || true)"
    [[ -n "$hit" ]] && die "claude settings '$f' declares $hit — the sanitizer cannot strip file-borne overrides; failing closed" "$EX_CONFIG"
  done
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
  STORY="${1:?usage: dispatch.sh <story.md> [cycle]}"
  CYCLE="${2:-1}"

  local router_dir
  router_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  CONFIG_FILE="${AGENT_FLOW_CONFIG:-${SUBSCRIPTIONS_FILE:-$router_dir/subscriptions.yaml}}"

  TMPFILES=()
  TERMINAL_HANDLE="" TERMINAL_TAIL="" HARNESS_EXIT=""
  trap 'rm -f "${TMPFILES[@]:-}"' EXIT

  for dep in yq jq curl orca; do
    command -v "$dep" >/dev/null || die "missing dependency: $dep"
  done
  [[ -f "$STORY" ]] || die "no such story: $STORY"

  # The worker's sandbox is rooted at $PWD — a story outside it is unreadable to
  # the worker even though it is readable here.
  case "$(realpath "$STORY")" in
    "$(realpath "$PWD")"/*) ;;
    *) die "story is OUTSIDE the current directory ($PWD) — the sandboxed worker cannot read it. cd into the Orca worktree and use a story path inside it." ;;
  esac

  # ---- launcher config (never from the story, never from the stamp) --------
  VALIDATOR="$(cfg '.launcher.stamp_validator' AGENT_STAMP_VALIDATE 'agent-stamp-validate')"
  CATALOG_PATH="$(cfg '.launcher.catalog_path' AGENT_STAMP_VALIDATE_CATALOG_PATH '')"
  ROUTER_URL="$(cfg '.launcher.router_endpoint' AGENT_ROUTER_URL '')"
  ROUTER_URL="${ROUTER_URL%/}"
  CALLER_TOKEN_ENV="$(cfg '.launcher.caller_token_env' AGENT_ROUTER_TOKEN_ENV 'AGENT_ROUTER_TOKEN')"
  AGENT_DIR="$(cfg '.launcher.agent_dir' AGENT_DIR '_bmad/bmm/agents')"
  LAUNCH_TIMEOUT="$(cfg '.launcher.launch_timeout_seconds' AGENT_FLOW_LAUNCH_TIMEOUT '5400')"

  command -v "$VALIDATOR" >/dev/null || die "missing stamp validator: $VALIDATOR"
  [[ -n "$CATALOG_PATH" && -f "$CATALOG_PATH" ]] || \
    die "no trusted catalog: set launcher.catalog_path or AGENT_STAMP_VALIDATE_CATALOG_PATH. It is NEVER taken from the stamp."

  # The declared context-budget policy, loaded BEFORE anything else this run
  # would do: before the stamp is opened, before Orca is asked anything, before
  # any placement. Its thresholds are the only ones that exist, so a host that
  # cannot read them has nothing to dispatch under.
  BUDGET_POLICY="$(cfg '.launcher.budget_policy' AGENT_FLOW_BUDGET_POLICY "$router_dir/context-budget-policy.yaml")"
  load_budget_policy "$BUDGET_POLICY"

  # ---- story frontmatter: everything OUTSIDE the closed stamp --------------
  # persona, gates, cycle policy and the stamp pointer are sibling keys. The
  # closed ExecutionStamp has no home for any of them and must not grow one.
  fm() { yq --front-matter=extract -r "$1 // \"\"" "$STORY"; }

  PERSONA="$(fm '.persona')"
  MAX_CYCLES="$(fm '.max_cycles')"; MAX_CYCLES="${MAX_CYCLES:-3}"
  STAMP_FILE="$(fm '.stamp')"; STAMP_FILE="${STAMP_FILE:-${STORY}.stamp.json}"
  mapfile -t GATES < <(yq --front-matter=extract -r '.gates[]?' "$STORY")

  if yq --front-matter=extract -e '.route' "$STORY" >/dev/null 2>&1; then
    die "story still carries a 'route:' frontmatter block. Routing moved to POST /v1/route + an immutable stamp; a local route block is no longer an authority and will not be honoured."
  fi

  # gates: [] used to yield status "done" with zero evidence. An ORCH story with
  # no gate has nothing that could tell success from a confident lie.
  local nonempty=0 g
  for g in "${GATES[@]:-}"; do [[ -n "$g" ]] && nonempty=1; done
  (( nonempty == 1 )) || die "story declares no gates. An empty gate list cannot distinguish done from claimed-done — refusing to dispatch."

  (( CYCLE <= MAX_CYCLES )) || die "max_cycles ($MAX_CYCLES) exceeded — escalate to human" "$EX_NEEDS_HUMAN"

  # ---- the closed ExecutionStamp ------------------------------------------
  [[ -f "$STAMP_FILE" ]] || die "no execution stamp at '$STAMP_FILE'. Call POST /v1/route, accept the recommendation, and stamp it (scripts/make-stamp.sh) before dispatching." "$EX_STAMP_UNCHECKABLE"
  jq -e . "$STAMP_FILE" >/dev/null 2>&1 || die "execution stamp '$STAMP_FILE' is not valid JSON" "$EX_STAMP_UNCHECKABLE"

  HARNESS="$(jq -r '.harness // ""' "$STAMP_FILE")"
  MODEL_PROFILE="$(jq -r '.model_profile // ""' "$STAMP_FILE")"
  EFFORT="$(jq -r '.effort // ""' "$STAMP_FILE")"
  PLACEMENT_REQUIRED="$(jq -r '.placement_required // false' "$STAMP_FILE")"
  PLACEMENT_POLICY="$(jq -r '.placement_policy // ""' "$STAMP_FILE")"
  ENTITLEMENT_POOL="$(jq -r '.entitlement_pool // ""' "$STAMP_FILE")"
  STAMP_COST_CLASS="$(jq -r '.cost_class // ""' "$STAMP_FILE")"
  STAMP_CATALOG_VERSION="$(jq -r '.catalog_version // ""' "$STAMP_FILE")"
  STAMP_EXPIRES_AT="$(jq -r '.expires_at // ""' "$STAMP_FILE")"
  STAMP_DIGEST="sha256:$(sha256_of "$STAMP_FILE")"

  [[ -n "$HARNESS" && -n "$MODEL_PROFILE" && -n "$EFFORT" ]] || \
    die "stamp is missing harness/model_profile/effort" "$EX_STAMP_UNCHECKABLE"

  # Effort is validated against the CLOSED set before anything is launched.
  effort_is_stampable "$EFFORT" || \
    die "stamped effort '$EFFORT' is not in the closed set ($STAMP_EFFORTS) — --effort fails OPEN on claude, so an unvalidated value would run silently at the wrong effort" "$EX_STAMP_INVALID"

  # Physical model comes from the SAME trusted catalog the validator loads.
  # dispatch.sh never invents a profile -> model mapping.
  PHYSICAL_MODEL="$(yq -r ".profiles.\"$MODEL_PROFILE\".physical[0].model_id // \"\"" "$CATALOG_PATH")"
  [[ -n "$PHYSICAL_MODEL" && "$PHYSICAL_MODEL" != "null" ]] || \
    die "catalog has no physical model for profile '$MODEL_PROFILE'" "$EX_STAMP_UNCHECKABLE"
  NATIVE_MODEL="$(native_model_arg "$PHYSICAL_MODEL")"

  # Hosting is the launch-class discriminator's catalog half, and it comes from
  # the same trusted document — never from the stamp, which a workload could
  # otherwise use to talk this adapter into a launch class it does not qualify
  # for. An absent value stays empty and fails the pair closed at the guard.
  PROFILE_HOSTING="$(yq -r ".profiles.\"$MODEL_PROFILE\".hosting // \"\"" "$CATALOG_PATH")"
  [[ "$PROFILE_HOSTING" == "null" ]] && PROFILE_HOSTING=""

  # The routed profile's context window, from the SAME trusted document, read
  # EXACTLY: never derived from a model id, never extended, never substituted,
  # and never taken from the stamp. A profile that declares none leaves this
  # empty, and the budget then reports NOT_EVALUATED rather than a number the
  # kit made up. (`claude/strong` declares none today; that is the honest
  # catalog state and is registered as a catalog gap.)
  PROFILE_MIN_CONTEXT="$(yq -r ".profiles.\"$MODEL_PROFILE\".min_context // \"\"" "$CATALOG_PATH")"
  [[ "$PROFILE_MIN_CONTEXT" == "null" ]] && PROFILE_MIN_CONTEXT=""

  # ---- persona: never a silent no-op --------------------------------------
  PERSONA_FILE=""
  if [[ -n "$PERSONA" ]]; then
    PERSONA_FILE="$AGENT_DIR/$PERSONA.md"
    [[ -f "$PERSONA_FILE" ]] || \
      die "persona '$PERSONA' is stamped on the story but '$PERSONA_FILE' does not exist. Persona injection must never silently no-op — fix AGENT_DIR (currently '$AGENT_DIR') or the persona name."
    log "persona: $PERSONA ($PERSONA_FILE)"
  else
    log "persona: none stamped"
  fi

  log "[$STORY] cycle $CYCLE/$MAX_CYCLES -> $HARNESS $MODEL_PROFILE ($NATIVE_MODEL) effort=$EFFORT"
  log "stamp: $STAMP_FILE $STAMP_DIGEST expires=$STAMP_EXPIRES_AT catalog=$STAMP_CATALOG_VERSION"

  # ---- the prompt is DATA, written by the launcher, never shell source -----
  PROMPT_FILE="${STORY}.prompt"
  {
    if [[ -n "$PERSONA_FILE" && "$HARNESS" != "claude" ]]; then
      # codex has no system-prompt flag in exec; the persona is prepended to the
      # prompt FILE, so its content still never becomes shell source.
      cat "$PERSONA_FILE"; printf '\n\n'
    fi
    cat <<EOF
Execute the story file at ${STORY} (cycle ${CYCLE} of ${MAX_CYCLES}).
Read it fully. Implement until every acceptance criterion is satisfied. Run the
gate commands listed in its frontmatter yourself before you consider the work
complete, and record what you did in the story's Dev Agent Record section.
Your process exiting 0 is not success: the gates are the arbiter, and they are
re-run independently after you finish.
If you hit a decision that genuinely needs a human, print one line starting with
'NEEDS-HUMAN:' describing the question, then stop.
EOF
    worker_discipline_paragraph "$STORY"
  } > "$PROMPT_FILE"

  # What the lifecycle artifacts looked like BEFORE this attempt ran. A
  # continuation artifact is not removed the way the result artifact is — the
  # next cycle is supposed to resume from it — so freshness is proved by
  # identity instead: an artifact byte-identical to the one that was already
  # there was not written by this worker, whatever it printed.
  CHECKPOINT_FILE="${STORY}.checkpoint.json"
  CONTINUATION_FILE="${STORY}.continuation.json"
  CONTINUATION_BEFORE=""
  [[ -f "$CONTINUATION_FILE" ]] && CONTINUATION_BEFORE="$(sha256_of "$CONTINUATION_FILE")"

  # ---- Orca visibility ----------------------------------------------------
  local selector repo_id
  selector="$(orca_worktree_selector "$(realpath "$PWD")")"
  [[ -n "$selector" ]] || \
    die "$PWD is not an Orca-managed worktree — the worker would be invisible to Orca. Create the story's worktree with 'orca worktree create', mirror the story into it, and dispatch from there."
  repo_id="${selector%%::*}"
  orca_setup_policy_gate "$repo_id"

  # ---- pre-dispatch sizing (FR-97, FR-98) ---------------------------------
  # Deliberately HERE: after the setup-policy gate, and before /v1/place, stamp
  # validation and the launch guard. Being told a story is too big to start is a
  # PLANNING outcome, and a planning outcome must not consume a placement, a
  # validation or a terminal to be delivered. Everything it needs already
  # exists: the catalog window, the declared policy, and the payload files
  # themselves — including the prompt file, which was written above.
  BUDGET_STATE="NOT_EVALUATED" BUDGET_REASON="CONTEXT_WINDOW_UNDECLARED"
  BUDGET_RATIO="" BUDGET_FINDINGS=()
  local payload_bytes=0 payload_table="" pfile pbytes payload_list payload_rc=0
  # Collected into a VARIABLE rather than read from a process substitution: a
  # PAYLOAD_REF_MISSING refusal has to end the dispatch, and `exit` inside
  # `< <(...)` only ends the subshell — the launch would carry on with an
  # estimate that quietly skipped an input.
  payload_list="$(budget_payload_paths)" || payload_rc=$?
  (( payload_rc == 0 )) || exit "$payload_rc"
  while IFS= read -r pfile; do
    [[ -n "$pfile" ]] || continue
    pbytes="$(file_bytes "$pfile")"
    payload_bytes=$(( payload_bytes + pbytes ))
    payload_table+="  ${pbytes} bytes  ${pfile}"$'\n'
  done <<< "$payload_list"

  BUDGET_ESTIMATE="$(budget_estimate_tokens "$payload_bytes" "$BUDGET_METHOD")" || \
    die "BUDGET_POLICY_UNREADABLE: estimate_method '$BUDGET_METHOD' declared in $BUDGET_POLICY_FILE is not a method this launcher implements. An estimate produced by an undeclared method would be a number with no defined meaning." "$EX_CONFIG"

  if [[ -n "$PROFILE_MIN_CONTEXT" ]]; then
    local ratio_ppm
    ratio_ppm="$(budget_ratio_ppm "$BUDGET_ESTIMATE" "$PROFILE_MIN_CONTEXT")" || \
      die "catalog profile '$MODEL_PROFILE' declares min_context '$PROFILE_MIN_CONTEXT', which is not a positive token count" "$EX_STAMP_UNCHECKABLE"
    BUDGET_RATIO="$(budget_ratio_decimal "$ratio_ppm")"
    BUDGET_STATE="OK"; BUDGET_REASON=""
    log "budget: estimate $BUDGET_ESTIMATE / window $PROFILE_MIN_CONTEXT = $BUDGET_RATIO (method $BUDGET_METHOD, window from CATALOG)"
    if budget_crosses "$ratio_ppm" "$BUDGET_CONTINUATION_PPM"; then
      refuse_story_sizing "${STORY}.blocked" "$BUDGET_ESTIMATE" "$PROFILE_MIN_CONTEXT" \
        "$BUDGET_RATIO" "$(budget_ratio_decimal "$BUDGET_CONTINUATION_PPM")" "$payload_table"
      log "STORY SIZING REFUSED: reason=SIZING_REFUSED — the planned payload is at or past the continuation threshold"
      log "  nothing placed, nothing validated, nothing launched — see ${STORY}.blocked"
      exit "$EX_SIZING_REFUSED"
    fi
    if budget_crosses "$ratio_ppm" "$BUDGET_RISK_PPM"; then
      BUDGET_FINDINGS+=("SIZING_RISK")
      record_budget_line "$STORY" "$CYCLE" SIZING_RISK \
        "$BUDGET_ESTIMATE/$PROFILE_MIN_CONTEXT ($BUDGET_RATIO)"
    fi
  else
    log "budget: catalog profile '$MODEL_PROFILE' declares no min_context — NOT_EVALUATED (CONTEXT_WINDOW_UNDECLARED). estimate $BUDGET_ESTIMATE tokens is recorded, no threshold can fire, and no window is invented."
  fi

  # ---- placement (fresh, per attempt) then FINAL validation ---------------
  EVIDENCE_FILE=""
  if [[ "$PLACEMENT_REQUIRED" == "true" ]]; then
    EVIDENCE_FILE="$(mktemp)"; TMPFILES+=("$EVIDENCE_FILE")
  fi
  place_if_required "$PLACEMENT_REQUIRED" "$MODEL_PROFILE" "$PLACEMENT_POLICY" "$EVIDENCE_FILE"

  VERDICT_FILE="$(mktemp)"; TMPFILES+=("$VERDICT_FILE" "$VERDICT_FILE.err")
  validate_stamp "$STAMP_FILE" "$EVIDENCE_FILE" "$VERDICT_FILE"

  # ---- launch-contract capability guard -----------------------------------
  # Runs AFTER validation (the router and the validator are the authorities on
  # whether this attempt MAY run) and BEFORE any harness command is built (this
  # adapter is the only authority on whether it CAN launch it). Nothing has been
  # created at this point: no terminal, no command text, no result artifact.
  local unsupported
  unsupported="$(unsupported_launch_reason "$HARNESS" "$MODEL_PROFILE" \
                   "$PLACEMENT_REQUIRED" "$ENTITLEMENT_POOL" \
                   "$PROFILE_HOSTING" "$STAMP_COST_CLASS")"
  if [[ -n "$unsupported" ]]; then
    refuse_unsupported_launch "$HARNESS" "$MODEL_PROFILE" "$EFFORT" \
      "$unsupported" "${STORY}.blocked"
    log "NO VALIDATED LAUNCH CONTRACT for {harness=$HARNESS, model_profile=$MODEL_PROFILE}"
    log "  $unsupported"
    log "  route NOT modified, no substitute chosen — see ${STORY}.blocked"
    exit "$EX_UNSUPPORTED_LAUNCH"
  fi

  # ---- launch -------------------------------------------------------------
  local title command_text exit_marker result_file=""
  title="$(basename "$STORY") ${HARNESS} ${MODEL_PROFILE} ${EFFORT} c${CYCLE}"

  local harness_bin
  harness_bin="$(cfg ".launcher.harness_binaries.$HARNESS" "" "$HARNESS")"
  command -v "$harness_bin" >/dev/null || die "harness binary '$harness_bin' not found on PATH"

  case "$HARNESS" in
    claude)
      local approved_home approved_path approved_user
      local gateway_url token_ref op_env_file placement_header max_context
      approved_home="$(resolve_approved_home)"
      claude_settings_preflight "$approved_home"
      approved_path="$(cfg '.launcher.approved_path' AGENT_FLOW_APPROVED_PATH "$(dirname "$(command -v "$harness_bin")"):/usr/local/bin:/usr/bin:/bin")"
      approved_user="$(id -un)"
      result_file="${STORY}.claude-result.json"
      # Removed BEFORE the preflights, not after them: a refusal that left last
      # cycle's artifact on disk would hand a reader that opens the file by name
      # a stale result for a launch that never happened.
      rm -f "$result_file"
      # Which of the two classes: the guard above already decided it, and this
      # reads the same stamp fact it decided on. A claude stamp that requires
      # placement and reached this line is a validated gateway-backed local
      # launch and nothing else.
      if [[ "$PLACEMENT_REQUIRED" == "true" ]]; then
        # Every preflight below runs while nothing exists yet: no terminal, no
        # command text, no result artifact. A gateway launch that cannot be
        # fully specified must not become a half-specified claude session.
        gateway_url="$(cfg '.launcher.gateway_endpoint' AGENT_FLOW_GATEWAY_URL '')"
        [[ -n "$gateway_url" ]] || \
          die "gateway-backed local launch needs launcher.gateway_endpoint (or AGENT_FLOW_GATEWAY_URL). It is LAUNCHER configuration and is never taken from the story, the stamp or the catalog" "$EX_CONFIG"
        token_ref="$(cfg '.launcher.gateway_token_ref' AGENT_FLOW_GATEWAY_TOKEN_REF '')"
        [[ -n "$token_ref" ]] || \
          die "gateway-backed local launch needs launcher.gateway_token_ref (or AGENT_FLOW_GATEWAY_TOKEN_REF) — a REFERENCE to the scoped gateway key, resolved at launch time. Its value never lives in config" "$EX_CONFIG"
        op_env_file="$(cfg '.launcher.op_env_file' AGENT_FLOW_OP_ENV_FILE "$approved_home/.op-agent-env")"
        [[ -r "$op_env_file" ]] || \
          die "the credential env file '$op_env_file' is not readable, so the reference could not be resolved at launch time and claude would start unauthenticated" "$EX_CONFIG"
        approved_path_has op "$approved_path" || \
          die "'op' is not on the approved PATH ($approved_path) — the gateway credential reference cannot be resolved at launch time" "$EX_CONFIG"
        # Copied VERBATIM from the evidence this attempt just fetched; never
        # composed here, and never carried over from a previous attempt.
        placement_header="$(jq -r '.result.headers["x-placement"] // ""' "$EVIDENCE_FILE" 2>/dev/null || true)"
        [[ -n "$placement_header" && "$placement_header" != "null" ]] || \
          die "the POST /v1/place evidence carries no x-placement header. The header value is copied verbatim from the place result, never composed, so there is nothing to convey and the launch is refused" "$EX_PLACEMENT"
        # The profile's real window. Claude Code does not recognise a local
        # model id, assumes 200000 tokens and compacts far too late for it.
        max_context="$(yq -r ".profiles.\"$MODEL_PROFILE\".min_context // \"\"" "$CATALOG_PATH")"
        [[ -n "$max_context" && "$max_context" != "null" ]] || \
          die "catalog profile '$MODEL_PROFILE' declares no min_context, so the session's real context window is unknown and the launch is refused rather than run at the harness default" "$EX_CONFIG"
        command_text="$(build_claude_gateway_command "$approved_home" "$approved_path" "$approved_user" \
                         "$PROMPT_FILE" "$NATIVE_MODEL" "$EFFORT" "$result_file" "$PERSONA_FILE" \
                         "$gateway_url" "$token_ref" "$op_env_file" "$placement_header" "$max_context")"
        log "launch class: gateway-backed local ($MODEL_PROFILE -> $NATIVE_MODEL at $gateway_url, x-placement $placement_header, context $max_context)"
      else
        command_text="$(build_claude_command "$approved_home" "$approved_path" "$approved_user" \
                         "$PROMPT_FILE" "$NATIVE_MODEL" "$EFFORT" "$result_file" "$PERSONA_FILE")"
        log "launch class: native vendor subscription"
      fi
      exit_marker="CLAUDE_EXIT"
      ;;
    codex)
      command_text="$(build_codex_command "$PROMPT_FILE" "$NATIVE_MODEL" "$EFFORT")"
      exit_marker="CODEX_EXIT"
      ;;
    *)
      die "no frozen launch contract for harness '$HARNESS'. Only claude and codex have one; adding another requires its own live validation and contract." ;;
  esac

  orca_launch "$selector" "$title" "$command_text" "$exit_marker" "$LAUNCH_TIMEOUT"

  # ---- post-launch honesty checks ----------------------------------------
  # `--effort` fails OPEN. The warning is a FAILURE even on exit 0: the run
  # completed at the DEFAULT effort, not the stamped one, and nothing in the
  # machine-readable output would ever reveal it.
  if grep -qaE "Unknown --effort value" <<<"$TERMINAL_TAIL"; then
    orca terminal rename --terminal "$TERMINAL_HANDLE" --title "$title ✗effort" >/dev/null 2>&1 || true
    die "claude reported an unknown --effort value: the turn ran at the DEFAULT effort, not the stamped '$EFFORT'. Treating as a launch failure." "$EX_STAMP_INVALID"
  fi

  WORKER_TEXT=""
  if [[ "$HARNESS" == "claude" && -f "$result_file" ]]; then
    WORKER_TEXT="$(jq -r '.result // ""' "$result_file" 2>/dev/null || true)"
    if [[ "$(jq -r '.is_error // false' "$result_file" 2>/dev/null || echo false)" == "true" ]]; then
      log "claude reported is_error=true (subtype is NOT a status field — gating on is_error)"
    fi
  else
    WORKER_TEXT="$TERMINAL_TAIL"
  fi

  # ---- human-needed marker ------------------------------------------------
  rm -f "${STORY}.blocked"
  if grep -qa '^NEEDS-HUMAN:' <<<"$WORKER_TEXT"; then
    grep -a '^NEEDS-HUMAN:' <<<"$WORKER_TEXT" > "${STORY}.blocked"
    orca terminal rename --terminal "$TERMINAL_HANDLE" --title "$title ⚑human" >/dev/null 2>&1 || true
    die "worker is blocked — see ${STORY}.blocked" "$EX_NEEDS_HUMAN"
  fi

  # ---- observed usage, then the artifacts the worker was told to leave -----
  # Deliberately AFTER the NEEDS-HUMAN exit (a blocked worker's usage is not a
  # budget verdict on the story) and BEFORE the gates: an attempt that stopped
  # at a phase boundary did not finish, and gates run over a deliberately
  # half-finished tree are evidence about the stop, not about the story.
  local observation
  observation="$(harness_usage_observation "$HARNESS" "${result_file:-}" "$NATIVE_MODEL")"
  budget_evaluate_usage "$observation" "$PROFILE_MIN_CONTEXT"

  # A checkpoint is a resumption aid, so an invalid one is a finding and not a
  # refusal: it costs the next cycle its head start, it does not make this
  # attempt's outcome a lie. A continuation artifact is the opposite — it is
  # the evidence for a status that says the work is unfinished — so it is held
  # to a refusal.
  BUDGET_CHECKPOINT_JSON=null BUDGET_CONTINUATION_JSON=null
  local verdict
  if [[ -f "$CHECKPOINT_FILE" ]]; then
    verdict="$(artifact_verdict "$CHECKPOINT_FILE" "afk-checkpoint/1" \
                 completed current_state remaining_acceptance next_steps updated_at)" || true
    if [[ "$verdict" == "VALID" ]]; then
      BUDGET_CHECKPOINT_JSON="$(artifact_identity_json "$CHECKPOINT_FILE")"
      log "budget: checkpoint artifact accepted ($CHECKPOINT_FILE)"
    else
      BUDGET_FINDINGS+=("CHECKPOINT_ARTIFACT_INVALID")
      log "budget: CHECKPOINT_ARTIFACT_INVALID ($verdict) — recorded, the attempt is not refused for it"
    fi
  fi

  RESULT_STATUS=""
  if grep -qa '^CONTINUATION-REQUIRED:' <<<"$WORKER_TEXT"; then
    local signal
    # The worker's own words are the one artifact-adjacent free text that
    # reaches a marker and a log, so they go through the redactor first.
    signal="$("$BUDGET_REDACT_FN" "$(grep -a '^CONTINUATION-REQUIRED:' <<<"$WORKER_TEXT" | tail -1)")"
    verdict="$(artifact_verdict "$CONTINUATION_FILE" "afk-continuation/1" \
                 completed current_state remaining_acceptance next_steps updated_at \
                 in_flight unretired_findings)" || true
    if [[ "$verdict" == "VALID" && -n "$CONTINUATION_BEFORE" \
          && "$CONTINUATION_BEFORE" == "$(sha256_of "$CONTINUATION_FILE")" ]]; then
      verdict="ARTIFACT_STALE"
    fi
    if [[ "$verdict" != "VALID" ]]; then
      # Loud, and never a manufactured completion: no result artifact is
      # written at all on this path, so nothing downstream can read an outcome
      # out of a run whose own evidence is missing.
      printf 'NEEDS-HUMAN: reason=CONTINUATION_ARTIFACT_INVALID detail=%s artifact=%s\n%s\n' \
        "$verdict" "$CONTINUATION_FILE" "$signal" > "${STORY}.blocked"
      orca terminal rename --terminal "$TERMINAL_HANDLE" --title "$title ⚑human" >/dev/null 2>&1 || true
      die "the worker signalled CONTINUATION-REQUIRED but its continuation artifact is $verdict — see ${STORY}.blocked" "$EX_NEEDS_HUMAN"
    fi
    BUDGET_CONTINUATION_JSON="$(artifact_identity_json "$CONTINUATION_FILE")"
    BUDGET_STATE="CONTINUATION_REQUIRED"; BUDGET_REASON=""
    RESULT_STATUS="continuation_required"
    record_budget_line "$STORY" "$CYCLE" CONTINUATION_REQUIRED \
      "$(jq -r .sha256 <<<"$BUDGET_CONTINUATION_JSON")"
    log "budget: $signal"
  fi

  # ---- deterministic gates: never trust the worker's word -----------------
  # A zero harness exit means the turn completed, not that the task succeeded.
  declare -A GATE_RESULTS; GATES_OK=true
  for g in "${GATES[@]:-}"; do
    [[ -z "$g" ]] && continue
    if bash -c "$g" >/dev/null 2>&1; then GATE_RESULTS["$g"]="pass"
    else GATE_RESULTS["$g"]="fail"; GATES_OK=false; fi
  done

  # Observed usage at or past the continuation threshold, with the gates failed
  # and no word from the worker, is the case where the kit can see that the
  # attempt ran out of room but the worker never said so. Reporting it as a
  # plain gate failure would invite a re-dispatch into the same wall; the kit
  # says continuation instead, and never claims a completion it cannot see.
  if [[ -z "$RESULT_STATUS" && "$GATES_OK" != true \
        && "$BUDGET_STATE" == "CONTINUATION_REQUIRED" ]]; then
    RESULT_STATUS="continuation_required"
    log "budget: usage reached the continuation band with gates failed and no worker signal"
  fi
  [[ -n "$RESULT_STATUS" ]] || \
    RESULT_STATUS="$([[ $GATES_OK == true ]] && echo 'done' || echo 'gates_failed')"

  # ---- thin result the PM can read without loading the transcript ---------
  local placement_json='{"required":false}'
  if [[ -n "$EVIDENCE_FILE" && -s "$EVIDENCE_FILE" ]]; then
    placement_json="$(jq -c '{required:true, placement:.result.placement,
                              model:.result.model, resolved_at:.resolved_at,
                              ttl_seconds:.result.ttl_seconds}' "$EVIDENCE_FILE")"
  fi

  jq -n \
    --arg story "$STORY" --arg cycle "$CYCLE" \
    --arg harness "$HARNESS" --arg profile "$MODEL_PROFILE" \
    --arg model "$NATIVE_MODEL" --arg effort "$EFFORT" \
    --arg persona "$PERSONA" \
    --arg digest "$STAMP_DIGEST" --arg expires "$STAMP_EXPIRES_AT" \
    --arg catalog "$STAMP_CATALOG_VERSION" \
    --arg terminal "$TERMINAL_HANDLE" --arg hexit "$HARNESS_EXIT" \
    --arg status "$RESULT_STATUS" \
    --argjson placement "$placement_json" \
    --argjson budget "$(jq -n \
        --arg st "$BUDGET_STATE" --arg rs "$BUDGET_REASON" \
        --arg win "$PROFILE_MIN_CONTEXT" --arg est "$BUDGET_ESTIMATE" \
        --arg method "$BUDGET_METHOD" --arg ratio "$BUDGET_RATIO" \
        --arg ut "$BUDGET_USAGE_TOKENS" --arg ur "$BUDGET_USAGE_RATIO" \
        --arg up "$BUDGET_USAGE_PROVENANCE" --arg oa "$BUDGET_OBSERVED_AT" \
        --arg ureason "$BUDGET_USAGE_REASON" \
        --arg wr "$BUDGET_WINDOW_REPORTED" \
        --argjson cp "$BUDGET_CHECKPOINT_JSON" --argjson ct "$BUDGET_CONTINUATION_JSON" \
        --argjson findings "$(printf '%s\n' ${BUDGET_FINDINGS[@]+"${BUDGET_FINDINGS[@]}"} \
                              | jq -R -s -c 'split("\n") | map(select(length > 0))')" \
        '{state:$st, reason:(if $rs == "" then null else $rs end),
          window_tokens:(if $win == "" then null else ($win|tonumber) end),
          window_source:"CATALOG",
          estimate_tokens:($est|tonumber), estimate_method:$method,
          estimate_ratio:(if $ratio == "" then null else ($ratio|tonumber) end),
          usage_tokens:(if $ut == "" then null else ($ut|tonumber) end),
          usage_ratio:(if $ur == "" then null else ($ur|tonumber) end),
          usage_provenance:$up,
          usage_reason:(if $ureason == "" then null else $ureason end),
          observed_at:(if $oa == "" then null else $oa end),
          window_reported_tokens:(if $wr == "" then null else ($wr|tonumber) end),
          checkpoint_artifact:$cp, continuation_artifact:$ct,
          findings:$findings}')" \
    --argjson gates "$(for k in "${!GATE_RESULTS[@]}"; do
                         jq -n --arg k "$k" --arg v "${GATE_RESULTS[$k]}" '{($k):$v}'
                       done | jq -s 'add // {}')" \
    '{story:$story, cycle:($cycle|tonumber), status:$status,
      route:{harness:$harness, model_profile:$profile, native_model:$model,
             effort:$effort, persona:$persona},
      stamp:{digest:$digest, expires_at:$expires, catalog_version:$catalog,
             validated:true},
      placement:$placement,
      budget:$budget,
      launch:{orca_terminal:$terminal, harness_exit:($hexit|tonumber?)},
      gates:$gates}' > "${STORY}.result.json"

  orca terminal rename --terminal "$TERMINAL_HANDLE" \
    --title "$title $([[ $GATES_OK == true ]] && echo '✓gates' || echo '✗gates')" >/dev/null 2>&1 || true

  log "$(jq -c . "${STORY}.result.json")"
  # A continuation is not a completion, whatever the gates said about a tree the
  # worker deliberately left half-finished: it exits as unfinished work so the
  # cycle loop treats it as work to resume rather than work to close.
  [[ "$GATES_OK" == true && "$RESULT_STATUS" == "done" ]] \
    && exit "$EX_DONE" || exit "$EX_GATES_FAILED"
}

# Sourced by tests/ to exercise the pure builders without running a dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
