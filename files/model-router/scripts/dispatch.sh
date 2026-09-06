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
"ANTHROPIC_AUTH_TOKEN=\"\$(. $(shq "$op_env_file") && op read $(shq "$token_ref"))\"; \
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
# The launch classes this adapter implements, all live-validated and frozen:
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
  } > "$PROMPT_FILE"

  # ---- Orca visibility ----------------------------------------------------
  local selector repo_id
  selector="$(orca_worktree_selector "$(realpath "$PWD")")"
  [[ -n "$selector" ]] || \
    die "$PWD is not an Orca-managed worktree — the worker would be invisible to Orca. Create the story's worktree with 'orca worktree create', mirror the story into it, and dispatch from there."
  repo_id="${selector%%::*}"
  orca_setup_policy_gate "$repo_id"

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
        rm -f "$result_file"
        command_text="$(build_claude_gateway_command "$approved_home" "$approved_path" "$approved_user" \
                         "$PROMPT_FILE" "$NATIVE_MODEL" "$EFFORT" "$result_file" "$PERSONA_FILE" \
                         "$gateway_url" "$token_ref" "$op_env_file" "$placement_header" "$max_context")"
        log "launch class: gateway-backed local ($MODEL_PROFILE -> $NATIVE_MODEL at $gateway_url, x-placement $placement_header, context $max_context)"
      else
        rm -f "$result_file"
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

  # ---- deterministic gates: never trust the worker's word -----------------
  # A zero harness exit means the turn completed, not that the task succeeded.
  declare -A GATE_RESULTS; GATES_OK=true
  for g in "${GATES[@]:-}"; do
    [[ -z "$g" ]] && continue
    if bash -c "$g" >/dev/null 2>&1; then GATE_RESULTS["$g"]="pass"
    else GATE_RESULTS["$g"]="fail"; GATES_OK=false; fi
  done

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
    --arg status "$([[ $GATES_OK == true ]] && echo 'done' || echo 'gates_failed')" \
    --argjson placement "$placement_json" \
    --argjson gates "$(for k in "${!GATE_RESULTS[@]}"; do
                         jq -n --arg k "$k" --arg v "${GATE_RESULTS[$k]}" '{($k):$v}'
                       done | jq -s 'add // {}')" \
    '{story:$story, cycle:($cycle|tonumber), status:$status,
      route:{harness:$harness, model_profile:$profile, native_model:$model,
             effort:$effort, persona:$persona},
      stamp:{digest:$digest, expires_at:$expires, catalog_version:$catalog,
             validated:true},
      placement:$placement,
      launch:{orca_terminal:$terminal, harness_exit:($hexit|tonumber?)},
      gates:$gates}' > "${STORY}.result.json"

  orca terminal rename --terminal "$TERMINAL_HANDLE" \
    --title "$title $([[ $GATES_OK == true ]] && echo '✓gates' || echo '✗gates')" >/dev/null 2>&1 || true

  log "$(jq -c . "${STORY}.result.json")"
  [[ "$GATES_OK" == true ]] && exit "$EX_DONE" || exit "$EX_GATES_FAILED"
}

# Sourced by tests/ to exercise the pure builders without running a dispatch.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
