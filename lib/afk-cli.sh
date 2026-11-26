#!/usr/bin/env bash
# afk-cli.sh — AFK's standalone route: `afk` in front of the agent CLIs
# installed on this machine (claude, codex, opencode, grok, agy).
#
# The factory runs agents for issues. This route is for a person at a
# terminal: it picks the harness, model and effort for one session with the
# same router the factory uses (benchmark scores, the usage left in each
# subscription pool, cost class), then hands the terminal to that CLI.
#
#   afk [options] [prompt...]        interactive session in the chosen CLI
#   afk -p [options] prompt...       one answer printed to stdout, with
#                                    failover to the next candidate
#   afk --explain [options] [prompt] the decision and the alternatives
#
# Sessions started here show up in pool usage on their own: the router counts
# each CLI's own session files.

AFK_CLI_HARNESSES=(claude codex opencode grok agy)

afk_cli_usage() {
  cat <<'EOF'
afk — run the best agent CLI on this machine for the task

  afk [options] [prompt...]          start an interactive session
  afk -p [options] prompt...         print one answer and exit
  afk --explain [options] [prompt]   show the choice and the alternatives

Options:
  -p, --print            one-shot: run headless and print the answer
  --prompt <text>        the prompt, when it starts with a dash
  --task <kind>          coding (default), quick, complex, review,
                         architecture, webdev, research, security.
                         Without it the kind is guessed from the prompt.
  --prefer <mode>        balanced (default), cheap (free and local first),
                         best (strongest model for the kind)
  --harness <name>       use this CLI (claude, codex, opencode, grok, agy)
  --model <id>           use this model; without --harness, the CLI that
                         serves it is looked up in the catalog
  --effort <level>       low, medium, high (claude, codex, grok, agy)
  --repo <dir>           project whose .afk/config.json router settings apply
                         (default: the current directory; the CLI still
                         starts in the current directory)
  --explain, --dry-run   show the decision and do not start anything
  --json                 machine-readable output for --explain and -p
  --yolo                 let the CLI act without asking (each CLI's own
                         skip-permissions flag); off by default
  --                     pass the remaining arguments to the CLI unchanged
  -h, --help             this help
EOF
}

# afk_cli_guess_task <prompt> -> task kind
# Word starts only, so "optimizing" and "vulnerability" match their stems.
# A prompt that asks for a change is never taken as research.
afk_cli_guess_task() {
  local p b='(^|[^a-z])'
  p="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$p" ]] || { printf 'coding'; return 0; }
  local action=false
  [[ "$p" =~ $b(fix|add|implement|write|build|create|make|update|change|remove|delete|port|wire)([^a-z]|$) ]] && action=true
  if [[ "$p" =~ $b(security|vulnerab|cve-|exploit|threat model|pentest|xss|csrf|sql injection|command injection|prompt injection|secret leak) ]]; then printf 'security'
  elif [[ "$p" =~ $b(review|audit|look over|critique) ]]; then printf 'review'
  elif [[ "$p" =~ $b(architect|design doc|system design|plan out|roadmap|prd([^a-z]|$)|spec out) ]]; then printf 'architecture'
  elif [[ "$p" =~ $b(refactor|migrat|rewrit|debug|race condition|deadlock|performance|optimi[sz]|concurren|memory leak) ]]; then printf 'complex'
  elif [[ "$p" =~ $b(css|html|frontend|front-end|react|vue|svelte|tailwind|ui|ux|landing page|web page|component|responsive)([^a-z]|$) ]]; then printf 'webdev'
  elif [[ "$action" == false && "$p" =~ $b(research|compare|explain|what is|what are|why does|how does|summari[sz]|investigat) ]]; then printf 'research'
  elif [[ "$p" =~ $b(rename|typo|format|lint|bump|quick|small|one-liner|comment)([^a-z]|$) ]]; then printf 'quick'
  else printf 'coding'; fi
}

# afk_cli_task_route <task> <prefer> -> "<stage> <risk>" for the router
afk_cli_task_route() {
  local task="$1" prefer="$2" stage risk="low"
  case "$task" in
    quick)        stage="build" ;;
    coding)       stage="build" ;;
    complex)      stage="build"; risk="high" ;;
    review)       stage="review-code" ;;
    architecture) stage="architecture" ;;
    webdev)       stage="ux" ;;
    research)     stage="research" ;;
    security)     stage="review-security" ;;
    *)            return 1 ;;
  esac
  # "best" asks for the strongest model the kind allows; "quick" never does.
  [[ "$prefer" == best && "$task" != quick ]] && risk="high"
  printf '%s %s' "$stage" "$risk"
}

# afk_cli_installed_harnesses -> the supported CLIs found on PATH
afk_cli_installed_harnesses() {
  local h out=()
  for h in "${AFK_CLI_HARNESSES[@]}"; do
    if [[ -n "${AFK_HARNESS_BIN_DIR_OVERRIDE:-}" ]]; then
      [[ -x "$AFK_HARNESS_BIN_DIR_OVERRIDE/$h" ]] && out+=("$h")
    else
      command -v "$h" >/dev/null 2>&1 && out+=("$h")
    fi
  done
  printf '%s\n' "${out[@]+"${out[@]}"}"
}

# afk_cli_bin <harness> -> path of its CLI
afk_cli_bin() {
  if [[ -n "${AFK_HARNESS_BIN_DIR_OVERRIDE:-}" ]]; then
    [[ -x "$AFK_HARNESS_BIN_DIR_OVERRIDE/$1" ]] && printf '%s' "$AFK_HARNESS_BIN_DIR_OVERRIDE/$1"
  else
    command -v "$1" 2>/dev/null
  fi
}

# afk_cli_harnesses_for_model <model> <installed-csv> -> "harness=model" pairs
# (comma-separated) for the installed CLIs the catalog says serve that model,
# with the model as that CLI names it.
afk_cli_harnesses_for_model() {
  local cat_file
  cat_file="$(afk_router_catalog_path 2>/dev/null || true)"
  [[ -f "$cat_file" ]] || return 0
  jq -j --arg m "$1" --arg inst ",$2," '
    [ .candidates[] | select(.model == $m or .canonical_model == $m) | {h: .harness, m: .model} ]
    | unique_by(.h) | map(. as $c | select(($inst | index("," + $c.h + ",")) != null) | "\(.h)=\(.m)") | join(",")' "$cat_file" 2>/dev/null
}

# afk_cli_route <repo> <task> <prefer> [<harness-list>] -> route JSON
# The router's decision for one task, limited to the given CLIs.
afk_cli_route() {
  local repo="$1" task="$2" prefer="$3" list="${4:-}" sr stage risk
  sr="$(afk_cli_task_route "$task" "$prefer")" || return 1
  stage="${sr% *}"; risk="${sr#* }"
  [[ -n "$list" ]] || list="$(afk_cli_installed_harnesses | paste -sd, -)"
  [[ -n "$list" ]] || return 2
  local pf="${AFK_ROUTER_PREFER_FREE:-}"
  [[ "$prefer" == cheap || "$task" == quick ]] && pf=1
  # In this shell, so the router sees the same state and live quota as the
  # factory; AFK_ROUTER_ONLY_HARNESSES limits the choice and nothing else.
  local r
  r="$(AFK_ROUTER_ONLY_HARNESSES="$list" AFK_ROUTER_PREFER_FREE="$pf" \
    afk_router_select_candidate "$repo" "$stage" "$risk" "" "" 1 "code" 0 2>/dev/null)"
  # The router's last-resort answer ignores the allowed CLIs. Outside them it
  # means nothing here can do the task, not "start that one anyway".
  if [[ "$(jq -r '.router_source // empty' <<<"$r" 2>/dev/null)" == fallback-default ]] \
     && [[ ",$list," != *",$(jq -r '.harness // empty' <<<"$r" 2>/dev/null),"* ]]; then
    return 3
  fi
  printf '%s' "$r"
}

# afk_cli_launch_env <route-json> -> NAME=value words (NUL-separated) the CLI
# needs for this route. A gateway route is sent to the gateway, never to the
# provider; one with no gateway address cannot be launched (status 1).
afk_cli_launch_env() {
  local lc url h
  lc="$(jq -r '.launch_class // empty' <<<"$1" 2>/dev/null)"
  [[ "$lc" == *-gateway ]] || return 0
  url="$(jq -r '.litellm_base_url // empty' <<<"$1" 2>/dev/null)"
  h="$(jq -r '.harness // empty' <<<"$1" 2>/dev/null)"
  [[ -n "$url" ]] || return 1
  case "$h" in
    claude) printf 'ANTHROPIC_BASE_URL=%s\0' "$url" ;;
    codex|opencode) printf 'OPENAI_BASE_URL=%s\0' "$url" ;;
    *) return 1 ;;
  esac
}

# afk_cli_launch_argv <harness> <model> <effort> <mode> <yolo> <prompt> <codex-out> [extra...]
# The command, NUL-separated. mode: interactive | print. In print mode each
# CLI writes JSON, so errors reported with exit 0 are still seen. Arguments
# after -- go before the prompt, so a CLI never reads them as prompt text.
afk_cli_launch_argv() {
  local h="$1" model="$2" effort="$3" mode="$4" yolo="$5" prompt="$6" cxout="$7"; shift 7
  local bin; bin="$(afk_cli_bin "$h")"
  [[ -n "$bin" ]] || return 1
  # A prompt that starts with a dash would be read as an option by some CLIs.
  [[ "$prompt" == -* ]] && prompt=" $prompt"
  local -a a=("$bin")
  case "$h" in
    claude)
      [[ -n "$model" ]] && a+=(--model "$model")
      [[ -n "$effort" ]] && a+=(--effort "$effort")
      [[ "$yolo" == true ]] && a+=(--dangerously-skip-permissions)
      [[ "$mode" == print ]] && a+=(-p --output-format json)
      a+=("$@")
      [[ -n "$prompt" ]] && a+=(-- "$prompt") ;;
    codex)
      [[ "$mode" == print ]] && a+=(exec --skip-git-repo-check --json -o "$cxout")
      [[ -n "$model" ]] && a+=(-m "$model")
      [[ -n "$effort" ]] && a+=(-c "model_reasoning_effort=\"$effort\"")
      [[ "$yolo" == true ]] && a+=(--dangerously-bypass-approvals-and-sandbox)
      a+=("$@")
      [[ -n "$prompt" ]] && a+=(-- "$prompt") ;;
    opencode)
      if [[ "$mode" == print ]]; then
        a+=(run --format json)
        [[ -n "$model" ]] && a+=(-m "$model")
        [[ "$yolo" == true ]] && a+=(--auto)
        a+=("$@" -- "$prompt")
      else
        [[ -n "$model" ]] && a+=(-m "$model")
        a+=("$@")
        [[ -n "$prompt" ]] && a+=("--prompt=$prompt")
      fi ;;
    grok)
      [[ -n "$model" ]] && a+=(-m "$model")
      [[ -n "$effort" ]] && a+=(--effort "$effort")
      [[ "$yolo" == true ]] && a+=(--always-approve)
      if [[ "$mode" == print ]]; then a+=(--output-format json "$@" "--single=$prompt")
      else a+=("$@"); [[ -n "$prompt" ]] && a+=(-- "$prompt"); fi ;;
    agy)
      local m="$model"
      # Antigravity names carry the effort tier; keep it in step with --effort.
      if [[ -n "$m" && -n "$effort" ]]; then
        case "$effort" in low|medium|high) m="${m%-low}"; m="${m%-medium}"; m="${m%-high}"; m="$m-$effort" ;; esac
      fi
      [[ -n "$m" ]] && a+=(--model "$m")
      [[ -n "$effort" ]] && a+=(--effort "$effort")
      [[ "$yolo" == true ]] && a+=(--dangerously-skip-permissions)
      if [[ "$mode" == print ]]; then a+=(--output-format json "$@" -p "$prompt")
      else a+=("$@"); [[ -n "$prompt" ]] && a+=(-i "$prompt"); fi ;;
    *) return 1 ;;
  esac
  printf '%s\0' "${a[@]}"
}

# afk_cli_result <stdout-file> <codex-out> -> answer text; status 1 when the
# JSON says the run failed (the error text is printed instead).
afk_cli_result() {
  local f="$1" cx="$2" t
  if [[ -s "$f" ]] && jq -se 'any(.[]; (.is_error == true) or (.type == "error") or (.type == "turn.failed"))' "$f" >/dev/null 2>&1; then
    jq -sr '[ .[] | (.error.data.message // .error.message // (if .is_error == true then .result else empty end) // .message // empty) | strings ] | map(select(length > 0)) | first // "the CLI reported an error"' "$f" 2>/dev/null
    return 1
  fi
  if [[ -s "$cx" ]]; then cat -- "$cx"; return 0; fi
  t="$(jq -sr '[ .[] | (.result // .response // .text // .part.text // empty) | strings ] | join("")' "$f" 2>/dev/null || true)"
  if [[ -n "$t" ]]; then printf '%s' "$t"; else cat -- "$f"; fi
}

# afk_cli_failure_kind <text> -> model|pool|other
# model: this model is refused (quarantine it); pool: sign-in, quota or rate
# limit (mark the pool); other: avoid this CLI for the rest of this run only.
afk_cli_failure_kind() {
  local t
  t="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$t" =~ (model_not_found|does[[:space:]]+not[[:space:]]+have[[:space:]]+access|not[[:space:]]+authorized[[:space:]]+for[[:space:]]+model|unknown[[:space:]]+model) ]]; then printf 'model'
  elif [[ "$t" =~ (401|unauthorized|not[[:space:]]+logged[[:space:]]+in|please[[:space:]]+log[[:space:]]?in|429|rate[[:space:]_]limit|quota|usage[[:space:]]+limit|credit[[:space:]]+balance|exhausted|overloaded|529) ]]; then printf 'pool'
  else printf 'other'; fi
}

afk_cli_mark_failure() { # <kind> <pool> <model> <reason>
  if [[ "$1" == model ]]; then afk_router_mark_model_unavailable "$3" "${4:0:160}" >/dev/null 2>&1 || true
  elif [[ "$1" == pool && -n "$2" ]]; then
    local why="$4" lw
    lw="$(printf '%s' "$why" | tr '[:upper:]' '[:lower:]')"
    # The router reads the reason to decide how long to avoid the pool. CLI
    # wording such as "usage limit reached" is a quota event it would not
    # otherwise recognise.
    if [[ "$lw" =~ (usage[[:space:]]+limit|credit[[:space:]]+balance) ]] && ! [[ "$lw" =~ (429|rate_limit|rate[[:space:]]+limit|quota) ]]; then why="quota: $why"; fi
    afk_router_mark_pool_degraded "$2" "${why:0:160}" >/dev/null 2>&1 || true
  fi
}

afk_cli_main() {
  local mode=interactive task="" prefer=balanced pin_h="" pin_m="" effort="" repo="$PWD"
  local explain=false json=false yolo=false prompt_opt="" x
  local -a words=() extra=()
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) afk_cli_usage; return 0 ;;
      -p|--print) mode=print ;;
      --prompt) prompt_opt="${2:-}"; shift ;;
      --prompt=*) prompt_opt="${1#*=}" ;;
      --task) task="${2:-}"; shift ;;
      --task=*) task="${1#*=}" ;;
      --prefer) prefer="${2:-}"; shift ;;
      --prefer=*) prefer="${1#*=}" ;;
      --harness) pin_h="${2:-}"; shift ;;
      --harness=*) pin_h="${1#*=}" ;;
      --model) pin_m="${2:-}"; shift ;;
      --model=*) pin_m="${1#*=}" ;;
      --effort) effort="${2:-}"; shift ;;
      --effort=*) effort="${1#*=}" ;;
      --repo) repo="${2:-}"; shift ;;
      --repo=*) repo="${1#*=}" ;;
      --explain|--dry-run) explain=true ;;
      --json) json=true ;;
      --yolo) yolo=true ;;
      --) shift; extra=("$@"); break ;;
      -*) printf 'afk: unknown option %s (see afk --help; a prompt that starts with a dash goes in --prompt)\n' "$1" >&2; return 2 ;;
      *) words+=("$1") ;;
    esac
    shift
  done
  local prompt="${words[*]+"${words[*]}"}"
  [[ -n "$prompt_opt" ]] && prompt="${prompt:+$prompt }$prompt_opt"
  case "$prefer" in balanced|cheap|best) ;; *) printf 'afk: --prefer must be balanced, cheap or best\n' >&2; return 2 ;; esac
  case "$effort" in ""|low|medium|high) ;; *) printf 'afk: --effort must be low, medium or high\n' >&2; return 2 ;; esac
  if [[ "$mode" == print && -z "$prompt" ]]; then
    if [[ ! -t 0 ]]; then prompt="$(cat)"; fi
    [[ -n "$prompt" ]] || { printf 'afk: -p needs a prompt\n' >&2; return 2; }
  fi
  local guessed=false
  if [[ -z "$task" ]]; then task="$(afk_cli_guess_task "$prompt")"; guessed=true; fi
  afk_cli_task_route "$task" "$prefer" >/dev/null || { printf 'afk: unknown --task %s\n' "$task" >&2; return 2; }

  local installed
  installed="$(afk_cli_installed_harnesses | paste -sd, -)"
  if [[ -z "$installed" ]]; then
    printf 'afk: none of %s is installed\n' "${AFK_CLI_HARNESSES[*]}" >&2; return 3
  fi
  if [[ -n "$pin_h" ]] && [[ ",$installed," != *",$pin_h,"* ]]; then
    printf 'afk: %s is not installed here (found: %s)\n' "$pin_h" "$installed" >&2; return 3
  fi
  # A model without a CLI: the CLI that serves it, from the catalog.
  if [[ -n "$pin_m" && -z "$pin_h" ]]; then
    local served
    served="$(afk_cli_harnesses_for_model "$pin_m" "$installed")"
    if [[ -z "$served" ]]; then
      printf 'afk: no installed CLI is known to serve %s; name one with --harness\n' "$pin_m" >&2; return 2
    elif [[ "$served" == *,* ]]; then
      printf 'afk: %s is served by %s; choose one with --harness\n' "$pin_m" "$(printf '%s' "$served" | sed 's/=[^,]*//g; s/,/ and /g')" >&2; return 2
    fi
    pin_h="${served%%=*}"; pin_m="${served#*=}"
  fi

  # The decision. A pinned harness and model skip the router entirely.
  local route="" list="${pin_h:-$installed}"
  if [[ -n "$pin_h" && -n "$pin_m" ]]; then
    route="$(jq -cn --arg h "$pin_h" --arg m "$pin_m" --arg e "${effort:-}" \
      '{harness:$h, model:$m, effort:(if $e == "" then null else $e end), entitlement_pool:null, reason:"pinned by --harness and --model", pinned:true}')"
  else
    route="$(afk_cli_route "$repo" "$task" "$prefer" "$list")"
    if [[ -z "$route" ]] || ! jq -e '.harness' <<<"$route" >/dev/null 2>&1; then
      printf 'afk: the router found no usable model for this task on %s\n' "$list" >&2; return 4
    fi
  fi
  [[ -n "$effort" ]] && route="$(jq -c --arg e "$effort" '.effort = $e' <<<"$route")"

  if [[ "$explain" == true ]]; then
    local alts="[]" h r
    if [[ -z "$pin_h" ]]; then
      for h in ${installed//,/ }; do
        r="$(afk_cli_route "$repo" "$task" "$prefer" "$h")" || continue
        jq -e '.harness' <<<"$r" >/dev/null 2>&1 || continue
        alts="$(jq -c --argjson r "$r" '. + [$r | {harness, model, effort, effective_score, entitlement_pool, pool_headroom_pct, pool_state, cost_class, benchmark_name, benchmark_basis}]' <<<"$alts")"
      done
      alts="$(jq -c 'sort_by(-(.effective_score // 0))' <<<"$alts")"
    fi
    if [[ "$json" == true ]]; then
      jq -cn --arg t "$task" --argjson g "$guessed" --arg p "$prefer" --argjson r "$route" --argjson a "$alts" \
        '{task:$t, task_guessed:$g, prefer:$p, choice:$r, by_harness:$a}'
    else
      printf 'task: %s%s  prefer: %s\n' "$task" "$([[ "$guessed" == true ]] && printf ' (guessed from the prompt)')" "$prefer"
      jq -r '"choice: \(.harness) / \(.model) [effort \(.effort // "default")]\n  pool: \(.entitlement_pool // "-") \(if .pool_headroom_pct then "(\(.pool_headroom_pct)% left, \(.pool_state))" else "" end)\n  score: \(.effective_score // "-") \(.benchmark_name // "") \(if .benchmark_basis then "[\(.benchmark_basis)]" else "" end)\n  why: \(.reason // "-")"' <<<"$route"
      if [[ "$alts" != "[]" ]]; then
        printf 'best per installed CLI:\n'
        jq -r '.[] | "  \(.harness | . + "         " | .[0:9]) \(.model) — score \(.effective_score), pool \(.entitlement_pool) \(.pool_headroom_pct)% left (\(.pool_state)), \(.cost_class)"' <<<"$alts"
      fi
    fi
    return 0
  fi

  local h m e
  h="$(jq -r '.harness' <<<"$route")"; m="$(jq -r '.model // empty' <<<"$route")"; e="$(jq -r '.effort // empty' <<<"$route")"

  if [[ "$mode" == interactive ]]; then
    local -a argv=() envv=()
    while IFS= read -r -d '' x; do argv+=("$x"); done < <(afk_cli_launch_argv "$h" "$m" "$e" interactive "$yolo" "$prompt" "" ${extra[@]+"${extra[@]}"})
    (( ${#argv[@]} > 0 )) || { printf 'afk: could not build a launch for %s\n' "$h" >&2; return 4; }
    if ! afk_cli_launch_env "$route" >/dev/null; then
      printf 'afk: %s / %s needs the model gateway and none is configured (AFK_LITELLM_BASE_URL)\n' "$h" "$m" >&2; return 4
    fi
    while IFS= read -r -d '' x; do envv+=("$x"); done < <(afk_cli_launch_env "$route")
    printf 'afk: %s / %s%s — %s\n' "$h" "$m" "$([[ -n "$e" ]] && printf ' (%s)' "$e")" "$(jq -r '.reason // ""' <<<"$route" | cut -c1-160)" >&2
    exec env ${envv[@]+"${envv[@]}"} "${argv[@]}"
  fi

  # One-shot: run, read the CLI's JSON, and on failure try the next candidate,
  # up to three attempts. A sign-in, quota or model failure is recorded for
  # the router (and so for the factory); anything else only keeps this run
  # away from that CLI. A pinned route never moves.
  local attempt=1 max=3 rc kind tried="" why ans avoid="" allowed="$list"
  local out err cxo
  out="$(mktemp "${TMPDIR:-/tmp}/afk-cli-out.XXXXXX")" || return 4
  err="$(mktemp "${TMPDIR:-/tmp}/afk-cli-err.XXXXXX")" || { rm -f -- "$out"; return 4; }
  cxo="$(mktemp "${TMPDIR:-/tmp}/afk-cli-cx.XXXXXX")" || { rm -f -- "$out" "$err"; return 4; }
  # shellcheck disable=SC2064
  trap "rm -f -- '$out' '$err' '$cxo'" RETURN
  while :; do
    local -a argv=() envv=()
    : > "$out"; : > "$err"; : > "$cxo"
    rc=0
    while IFS= read -r -d '' x; do argv+=("$x"); done < <(afk_cli_launch_argv "$h" "$m" "$e" print "$yolo" "$prompt" "$cxo" ${extra[@]+"${extra[@]}"})
    if (( ${#argv[@]} == 0 )) || ! afk_cli_launch_env "$route" >/dev/null; then
      rc=127; printf 'cannot launch %s / %s here (missing CLI or gateway)\n' "$h" "$m" > "$err"
    else
      while IFS= read -r -d '' x; do envv+=("$x"); done < <(afk_cli_launch_env "$route")
      env ${envv[@]+"${envv[@]}"} "${argv[@]}" < /dev/null > "$out" 2> "$err" || rc=$?
    fi
    tried="${tried}${tried:+, }$h/$m"
    if (( rc == 0 )) && ans="$(afk_cli_result "$out" "$cxo")"; then
      if [[ "$json" == true ]]; then
        jq -cn --arg o "$ans" --argjson r "$route" --argjson n "$attempt" '{ok:true, harness:$r.harness, model:$r.model, effort:$r.effort, attempts:$n, output:$o}'
      else
        printf '%s\n' "$ans"
      fi
      return 0
    fi
    (( rc == 0 )) && rc=1
    why="$( { [[ -n "${ans:-}" ]] && printf '%s\n' "$ans"; head -c 1500 "$err"; afk_cli_result "$out" "$cxo" 2>/dev/null | head -c 500; } | tr -d '\033' | head -c 600)"
    ans=""
    kind="$(afk_cli_failure_kind "$why")"
    if [[ "$(jq -r '.pinned // false' <<<"$route")" == true || -n "$pin_h" || -n "$pin_m" ]] || (( attempt >= max )); then
      # Still tell the router, so the factory does not walk into it too.
      afk_cli_mark_failure "$kind" "$(jq -r '.entitlement_pool // empty' <<<"$route")" "$m" "$why"
      if [[ "$json" == true ]]; then
        jq -cn --arg t "$tried" --arg w "$why" --argjson rc "$rc" '{ok:false, tried:$t, exit:$rc, error:$w}'
      else
        printf 'afk: %s failed (exit %s): %s\n' "$tried" "$rc" "$why" >&2
      fi
      return 5
    fi
    afk_cli_mark_failure "$kind" "$(jq -r '.entitlement_pool // empty' <<<"$route")" "$m" "$why"
    if [[ "$kind" == other ]]; then
      avoid="$avoid,$h"
      allowed="$(printf '%s' "$list" | tr ',' '\n' | grep -v -x -F -f <(printf '%s\n' "${avoid//,/$'\n'}" | sed '/^$/d') | paste -sd, -)"
    fi
    route=""
    [[ -n "$allowed" ]] && route="$(afk_cli_route "$repo" "$task" "$prefer" "$allowed")"
    if [[ -z "$route" ]] || ! jq -e '.harness' <<<"$route" >/dev/null 2>&1; then
      if [[ "$json" == true ]]; then
        jq -cn --arg t "$tried" --arg w "$why" --argjson rc "$rc" '{ok:false, tried:$t, exit:$rc, error:$w}'
      else
        printf 'afk: %s failed and no other model is usable: %s\n' "$tried" "$why" >&2
      fi
      return 5
    fi
    [[ -n "$effort" ]] && route="$(jq -c --arg e "$effort" '.effort = $e' <<<"$route")"
    h="$(jq -r '.harness' <<<"$route")"; m="$(jq -r '.model // empty' <<<"$route")"; e="$(jq -r '.effort // empty' <<<"$route")"
    printf 'afk: %s failed (%s); trying %s / %s\n' "${tried##*, }" "$kind" "$h" "$m" >&2
    attempt=$((attempt + 1))
  done
}
