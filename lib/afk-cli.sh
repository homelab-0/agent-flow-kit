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
  --task <kind>          coding (default), quick, complex, review,
                         architecture, webdev, research, security.
                         Without it the kind is guessed from the prompt.
  --prefer <mode>        balanced (default), cheap (free and local first),
                         best (strongest model for the kind)
  --harness <name>       use this CLI (claude, codex, opencode, grok, agy)
  --model <id>           use this model (with --harness, or one the catalog
                         knows)
  --effort <level>       low, medium, high (where the CLI supports it)
  --repo <dir>           project whose .afk/config.json router settings apply
                         (default: the current directory)
  --explain, --dry-run   show the decision and do not start anything
  --json                 machine-readable output for --explain and -p
  --yolo                 let the CLI act without asking (each CLI's own
                         skip-permissions flag); off by default
  --                     pass the remaining arguments to the CLI unchanged
  -h, --help             this help
EOF
}

# afk_cli_guess_task <prompt> -> task kind
afk_cli_guess_task() {
  local p
  p="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$p" ]] || { printf 'coding'; return 0; }
  if [[ "$p" =~ (^|[^a-z])(security|vulnerab|cve|exploit|threat model|pentest|xss|csrf|injection)([^a-z]|$) ]]; then printf 'security'
  elif [[ "$p" =~ (^|[^a-z])(review|audit|look over|critique|code review)([^a-z]|$) ]]; then printf 'review'
  elif [[ "$p" =~ (^|[^a-z])(architect|architecture|design doc|system design|plan out|roadmap|prd|spec out)([^a-z]|$) ]]; then printf 'architecture'
  elif [[ "$p" =~ (^|[^a-z])(css|html|frontend|front-end|react|vue|svelte|tailwind|ui|ux|landing page|web page|component)([^a-z]|$) ]]; then printf 'webdev'
  elif [[ "$p" =~ (^|[^a-z])(research|compare|explain|what is|what are|why does|how does|summari[sz]e|investigate)([^a-z]|$) ]]; then printf 'research'
  elif [[ "$p" =~ (^|[^a-z])(refactor|migrate|migration|rewrite|debug|race condition|deadlock|performance|optimi[sz]e|concurren)([^a-z]|$) ]]; then printf 'complex'
  elif [[ "$p" =~ (^|[^a-z])(rename|typo|format|lint|bump|quick|small|one-liner|comment)([^a-z]|$) ]]; then printf 'quick'
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

# afk_cli_launch_argv <harness> <model> <effort> <mode> <yolo> <prompt> [extra...]
# Prints the command, one argument per line, NUL-free. mode: interactive|print
afk_cli_launch_argv() {
  local h="$1" model="$2" effort="$3" mode="$4" yolo="$5" prompt="$6"; shift 6
  local bin; bin="$(afk_cli_bin "$h")"
  [[ -n "$bin" ]] || return 1
  local -a a=("$bin")
  case "$h" in
    claude)
      [[ -n "$model" ]] && a+=(--model "$model")
      [[ -n "$effort" ]] && a+=(--effort "$effort")
      [[ "$yolo" == true ]] && a+=(--dangerously-skip-permissions)
      if [[ "$mode" == print ]]; then a+=(-p "$prompt"); elif [[ -n "$prompt" ]]; then a+=("$prompt"); fi ;;
    codex)
      if [[ "$mode" == print ]]; then a+=(exec); fi
      [[ -n "$model" ]] && a+=(-m "$model")
      [[ -n "$effort" ]] && a+=(-c "model_reasoning_effort=\"$effort\"")
      [[ "$yolo" == true ]] && a+=(--dangerously-bypass-approvals-and-sandbox)
      [[ -n "$prompt" ]] && a+=(-- "$prompt") ;;
    opencode)
      if [[ "$mode" == print ]]; then
        a+=(run)
        [[ -n "$model" ]] && a+=(-m "$model")
        a+=(-- "$prompt")
      else
        [[ -n "$model" ]] && a+=(-m "$model")
        [[ -n "$prompt" ]] && a+=(--prompt "$prompt")
      fi ;;
    grok)
      [[ -n "$model" ]] && a+=(-m "$model")
      [[ -n "$effort" ]] && a+=(--effort "$effort")
      [[ "$yolo" == true ]] && a+=(--always-approve)
      if [[ "$mode" == print ]]; then a+=(-p "$prompt"); elif [[ -n "$prompt" ]]; then a+=("$prompt"); fi ;;
    agy)
      local m="$model"
      # Antigravity names carry the effort tier.
      if [[ -n "$m" && -n "$effort" && "$m" != *-low && "$m" != *-medium && "$m" != *-high ]]; then
        case "$effort" in low|medium|high) m="$m-$effort" ;; esac
      fi
      [[ -n "$m" ]] && a+=(--model "$m")
      [[ -n "$effort" ]] && a+=(--effort "$effort")
      [[ "$yolo" == true ]] && a+=(--dangerously-skip-permissions)
      if [[ "$mode" == print ]]; then a+=(-p "$prompt"); elif [[ -n "$prompt" ]]; then a+=(-i "$prompt"); fi ;;
    *) return 1 ;;
  esac
  a+=("$@")
  printf '%s\0' "${a[@]}"
}

# afk_cli_failure_kind <exit> <stderr-text> -> none|model|pool|other
# model: this model is refused (quarantine the model); anything else marks the
# pool, and the router reads the reason to pick how long.
afk_cli_failure_kind() {
  local rc="$1" t
  (( rc == 0 )) && { printf 'none'; return 0; }
  t="$(printf '%s' "${2:-}" | tr '[:upper:]' '[:lower:]')"
  if [[ "$t" =~ (model_not_found|does[[:space:]]+not[[:space:]]+have[[:space:]]+access|not[[:space:]]+authorized[[:space:]]+for[[:space:]]+model|unknown[[:space:]]+model) ]]; then printf 'model'
  elif [[ "$t" =~ (401|unauthorized|not[[:space:]]+logged[[:space:]]+in|login|429|rate[[:space:]_]limit|quota|usage[[:space:]]+limit|exhausted|overloaded|529) ]]; then printf 'pool'
  else printf 'other'; fi
}

afk_cli_mark_failure() { # <kind> <pool> <model> <reason>
  if [[ "$1" == model ]]; then afk_router_mark_model_unavailable "$3" "${4:0:160}" >/dev/null 2>&1 || true
  elif [[ -n "$2" ]]; then afk_router_mark_pool_degraded "$2" "${4:0:160}" >/dev/null 2>&1 || true; fi
}

afk_cli_main() {
  local mode=interactive task="" prefer=balanced pin_h="" pin_m="" effort="" repo="$PWD"
  local explain=false json=false yolo=false
  local -a words=() extra=()
  while (( $# > 0 )); do
    case "$1" in
      -h|--help) afk_cli_usage; return 0 ;;
      -p|--print) mode=print ;;
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
      -*) printf 'afk: unknown option %s (see afk --help)\n' "$1" >&2; return 2 ;;
      *) words+=("$1") ;;
    esac
    shift
  done
  local prompt="${words[*]+"${words[*]}"}"
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
    if [[ -n "$pin_m" ]]; then route="$(jq -c --arg m "$pin_m" '.model = $m | .reason = ("model pinned by --model; " + (.reason // ""))' <<<"$route")"; fi
  fi
  [[ -n "$effort" ]] && route="$(jq -c --arg e "$effort" '.effort = $e' <<<"$route")"

  if [[ "$explain" == true ]]; then
    local alts="[]" h r
    if [[ -z "$pin_h" ]]; then
      for h in ${installed//,/ }; do
        r="$(afk_cli_route "$repo" "$task" "$prefer" "$h")"
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
    local -a argv=()
    while IFS= read -r -d '' x; do argv+=("$x"); done < <(afk_cli_launch_argv "$h" "$m" "$e" interactive "$yolo" "$prompt" ${extra[@]+"${extra[@]}"})
    (( ${#argv[@]} > 0 )) || { printf 'afk: could not build a launch for %s\n' "$h" >&2; return 4; }
    printf 'afk: %s / %s%s — %s\n' "$h" "$m" "$([[ -n "$e" ]] && printf ' (%s)' "$e")" "$(jq -r '.reason // ""' <<<"$route" | cut -c1-160)" >&2
    exec "${argv[@]}"
  fi

  # One-shot: run, and on a launch, login, quota or model failure mark it and
  # try the next candidate, up to three attempts. A pinned route never moves.
  local attempt=1 max=3 out err rc kind tried=""
  err="$(mktemp "${TMPDIR:-/tmp}/afk-cli-err.XXXXXX")" || return 4
  while :; do
    local -a argv=()
    while IFS= read -r -d '' x; do argv+=("$x"); done < <(afk_cli_launch_argv "$h" "$m" "$e" print "$yolo" "$prompt" ${extra[@]+"${extra[@]}"})
    rc=0
    out="$("${argv[@]}" < /dev/null 2>"$err")" || rc=$?
    kind="$(afk_cli_failure_kind "$rc" "$(head -c 4000 "$err")")"
    tried="${tried}${tried:+, }$h/$m"
    if [[ "$kind" == none ]]; then
      rm -f -- "$err"
      if [[ "$json" == true ]]; then
        jq -cn --arg o "$out" --argjson r "$route" --argjson n "$attempt" '{ok:true, harness:$r.harness, model:$r.model, effort:$r.effort, attempts:$n, output:$o}'
      else
        printf '%s\n' "$out"
      fi
      return 0
    fi
    # Any failure moves on, as in the factory: the router decides from the
    # error how long to avoid that pool (a day for sign-in, an hour for quota,
    # fifteen minutes otherwise). Only a pinned route stays put.
    if [[ "$(jq -r '.pinned // false' <<<"$route")" == true || -n "$pin_h" ]] || (( attempt >= max )); then
      local why; why="$(head -c 600 "$err")"; rm -f -- "$err"
      if [[ "$json" == true ]]; then
        jq -cn --arg t "$tried" --arg w "$why" --argjson rc "$rc" '{ok:false, tried:$t, exit:$rc, error:$w}'
      else
        printf 'afk: %s failed (exit %s): %s\n' "$tried" "$rc" "$why" >&2
      fi
      return 5
    fi
    afk_cli_mark_failure "$kind" "$(jq -r '.entitlement_pool // empty' <<<"$route")" "$m" "$(head -c 160 "$err" | tr -d '\033')"
    route="$(afk_cli_route "$repo" "$task" "$prefer" "$installed")"
    jq -e '.harness' <<<"$route" >/dev/null 2>&1 || { rm -f -- "$err"; printf 'afk: %s failed and no other model is usable\n' "$tried" >&2; return 5; }
    [[ -n "$effort" ]] && route="$(jq -c --arg e "$effort" '.effort = $e' <<<"$route")"
    h="$(jq -r '.harness' <<<"$route")"; m="$(jq -r '.model // empty' <<<"$route")"; e="$(jq -r '.effort // empty' <<<"$route")"
    printf 'afk: %s failed (%s); trying %s / %s\n' "${tried##*, }" "$kind" "$h" "$m" >&2
    attempt=$((attempt + 1))
  done
}
