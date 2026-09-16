#!/usr/bin/env bash
# Shared, side-effect-free adapter-manager primitives. This file is sourced by
# manage.sh; loading it must only define functions.
# shellcheck shell=bash
# shellcheck disable=SC2034,SC2154

file_id() { stat -Lc '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null; }
open_file_id() { # descriptor path
  /usr/bin/stat -Lc '%d:%i' "$1" 2>/dev/null || /usr/bin/stat -f '%d:%i' "$1" 2>/dev/null \
    || /bin/stat -Lc '%d:%i' "$1" 2>/dev/null || /bin/stat -f '%d:%i' "$1" 2>/dev/null
}
process_incarnation() { # pid
  local stat_line fields boot_id stamp sum rest
  kill -0 "$1" 2>/dev/null || return 1
  if [[ -r "/proc/$1/stat" ]]; then
    stat_line="$(<"/proc/$1/stat")" || return 1
    stat_line="${stat_line##*) }"
    read -r -a fields <<<"$stat_line"
    [[ "${#fields[@]}" -ge 20 && "${fields[19]}" =~ ^[0-9]+$ ]] || return 1
    boot_id="$(</proc/sys/kernel/random/boot_id)" || return 1
    read -r sum rest <<<"$(printf '%s:%s' "$boot_id" "${fields[19]}" | LC_ALL=C cksum)"
    [[ -n "$sum" ]] || return 1
    printf '%s\n' "$sum"
    return 0
  fi
  stamp="$(LC_ALL=C TZ=UTC0 ps -p "$1" -o lstart= 2>/dev/null)" || return 1
  [[ -n "$stamp" ]] || return 1
  read -r sum rest <<<"$(printf '%s' "$stamp" | LC_ALL=C cksum)"
  [[ -n "$sum" ]] || return 1
  printf '%s\n' "$sum"
}
release_manager_lock() {
  local owner_id="" candidate_id=""
  if [[ -n "${manager_lock_owner:-}" && -n "${manager_lock_candidate:-}" \
    && ! -L "$manager_lock_owner" && -f "$manager_lock_owner" \
    && ! -L "$manager_lock_candidate" && -f "$manager_lock_candidate" ]]; then
    owner_id="$(file_id "$manager_lock_owner" 2>/dev/null || true)"
    candidate_id="$(file_id "$manager_lock_candidate" 2>/dev/null || true)"
    if [[ -n "$owner_id" && "$owner_id" == "$candidate_id" ]]; then /bin/rm -f "$manager_lock_owner"; fi
  fi
  if [[ -n "${manager_lock_candidate:-}" && ! -L "$manager_lock_candidate" ]]; then
    /bin/rm -f "$manager_lock_candidate"
  fi
  if [[ -n "${manager_lock:-}" ]]; then
    rmdir -- "$manager_lock" 2>/dev/null || true
  fi
  manager_lock_owner=""
  manager_lock_candidate=""
}
read_manager_lock_owner() { # path
  local value
  [[ ! -L "$1" && -f "$1" ]] || return 1
  value="$(<"$1")" || return 1
  [[ "$value" =~ ^([0-9]+)[[:space:]]([0-9]+|live)$ ]] || return 1
  LOCK_PID="${BASH_REMATCH[1]}"; LOCK_INC="${BASH_REMATCH[2]}"
}
manager_owner_is_live() { # pid incarnation
  local live_inc=""
  kill -0 "$1" 2>/dev/null || return 1
  live_inc="$(process_incarnation "$1" 2>/dev/null || true)"
  [[ "$2" == live || -z "$live_inc" || "$live_inc" == "$2" ]]
}
make_manager_lock_candidate() {
  local self_inc attempt old_umask fd_id path_id after_fd after_path current_id
  self_inc="$(process_incarnation "$$" 2>/dev/null || printf live)"
  old_umask="$(umask)"
  for ((attempt=0; attempt<8; attempt++)); do
    manager_lock_candidate="$STATE_DIR/adapters/.manage-$HARNESS.candidate.$$.$self_inc.$attempt"
    umask 077
    set -C
    if exec 9>"$manager_lock_candidate"; then
      set +C; umask "$old_umask"
      fd_id="$(open_file_id /dev/fd/9 2>/dev/null || true)"
      path_id="$(file_id "$manager_lock_candidate" 2>/dev/null || true)"
      if [[ -n "$fd_id" && "$fd_id" == "$path_id" && ! -L "$manager_lock_candidate" && -f "$manager_lock_candidate" ]] \
        && printf '%s %s\n' "$$" "$self_inc" >&9; then
        after_fd="$(open_file_id /dev/fd/9 2>/dev/null || true)"
        after_path="$(file_id "$manager_lock_candidate" 2>/dev/null || true)"
        exec 9>&-
        if [[ -n "$after_fd" && "$fd_id" == "$after_fd" && "$fd_id" == "$after_path" \
          && ! -L "$manager_lock_candidate" && -f "$manager_lock_candidate" ]]; then return 0; fi
      else
        exec 9>&-
      fi
      current_id="$(file_id "$manager_lock_candidate" 2>/dev/null || true)"
      if [[ -n "$fd_id" && "$current_id" == "$fd_id" && ! -L "$manager_lock_candidate" ]]; then
        /bin/rm -f "$manager_lock_candidate"
      fi
      manager_lock_candidate=""
      return 1
    else
      set +C; umask "$old_umask"
    fi
  done
  manager_lock_candidate=""
  return 1
}
acquire_manager_lock() {
  local owner_id reclaim_id attempt
  if ! (umask 077; mkdir -- "$manager_lock") 2>/dev/null; then
    [[ ! -L "$manager_lock" && -d "$manager_lock" ]] || return 1
  fi
  manager_lock_owner="$manager_lock/owner"
  make_manager_lock_candidate || { release_manager_lock; return 1; }
  for ((attempt=0; attempt<6; attempt++)); do
    if [[ -e "$manager_lock_reclaim" || -L "$manager_lock_reclaim" ]]; then
      [[ ! -L "$manager_lock_reclaim" && -f "$manager_lock_reclaim" ]] \
        || { release_manager_lock; return 1; }
      if [[ ! -e "$manager_lock_owner" && ! -L "$manager_lock_owner" ]]; then
        /bin/rm -f "$manager_lock_reclaim" || { release_manager_lock; return 2; }
        continue
      fi
      read_manager_lock_owner "$manager_lock_owner" || { release_manager_lock; return 1; }
      manager_owner_is_live "$LOCK_PID" "$LOCK_INC" && { release_manager_lock; return 2; }
      owner_id="$(file_id "$manager_lock_owner" 2>/dev/null || true)"; reclaim_id="$(file_id "$manager_lock_reclaim" 2>/dev/null || true)"
      [[ -n "$owner_id" && "$owner_id" == "$reclaim_id" ]] || { release_manager_lock; return 1; }
      if /bin/rm -f "$manager_lock_owner"; then /bin/rm -f "$manager_lock_reclaim"; continue; fi
      release_manager_lock; return 2
    fi
    if [[ ! -e "$manager_lock_owner" && ! -L "$manager_lock_owner" ]]; then
      if /bin/ln "$manager_lock_candidate" "$manager_lock_owner" 2>/dev/null; then
        owner_id="$(file_id "$manager_lock_owner" 2>/dev/null || true)"; reclaim_id="$(file_id "$manager_lock_candidate" 2>/dev/null || true)"
        [[ -n "$owner_id" && "$owner_id" == "$reclaim_id" ]] && return 0
        release_manager_lock; return 1
      fi
      continue
    fi
    read_manager_lock_owner "$manager_lock_owner" || { release_manager_lock; return 1; }
    manager_owner_is_live "$LOCK_PID" "$LOCK_INC" && { release_manager_lock; return 2; }
    /bin/ln "$manager_lock_owner" "$manager_lock_reclaim" 2>/dev/null || { release_manager_lock; return 2; }
  done
  release_manager_lock; return 2
}
afk_auto_update_supported() { [[ "${OSTYPE:-}" == linux* ]]; }
file_sha256() {
  local digest rest
  if [[ -x /usr/bin/sha256sum ]]; then read -r digest rest < <(/usr/bin/sha256sum "$1")
  elif [[ -x /bin/sha256sum ]]; then read -r digest rest < <(/bin/sha256sum "$1")
  elif [[ -x /usr/bin/shasum ]]; then read -r digest rest < <(/usr/bin/shasum -a 256 "$1")
  else return 1; fi
  [[ -n "$digest" ]] || return 1
  printf '%s\n' "$digest"
}
regular_file_sha256() { [[ ! -L "$1" && -f "$1" ]] && file_sha256 "$1"; }
record_identity_valid() { # record
  case "$HARNESS" in
    claude)
      jq -e --arg t "$HOME_ROOT/.claude/settings.json" --arg b "$STATE_DIR/adapters/claude-prior.json" \
        --arg c "$claude_command" --arg u "$session_start" --arg p "$claude_compact" \
        --arg i "$claude_instruction" --arg q "$claude_prompt" '
        .schema=="afk-adapter-install/3" and .harness=="claude"
        and (.phase=="installing" or .phase=="active") and .target==$t and .backup==$b
        and (.auto_update|type)=="boolean"
        and .command==$c and .updater==(if .auto_update then $u else "" end)
        and .compact==$p and .instruction==$i and .prompt==$q' "$1" >/dev/null 2>&1 ;;
    codex)
      jq -e --arg t "$HOME_ROOT/.codex/config.toml" --arg h "$HOME_ROOT/.codex/hooks.json" \
        --arg b "$STATE_DIR/adapters/codex-prior.json" --arg c "$codex_command" \
        --arg u "$session_start" --arg i "$codex_instruction" '
        .schema=="afk-adapter-install/3" and .harness=="codex"
        and (.phase=="installing" or .phase=="active") and .target==$t and .hooks==$h and .backup==$b
        and (.auto_update|type)=="boolean"
        and .command==$c and .updater==(if .auto_update then $u else "" end) and .instruction==$i' "$1" >/dev/null 2>&1 ;;
    opencode)
      jq -e --arg j "$HOME_ROOT/.config/opencode/opencode.json" --arg jc "$HOME_ROOT/.config/opencode/opencode.jsonc" \
        --arg b "$STATE_DIR/adapters/opencode-prior.json" --arg p "$opencode_plugin" '
        .schema=="afk-adapter-install/3" and .harness=="opencode"
        and (.phase=="installing" or .phase=="active") and (.target==$j or .target==$jc)
        and .backup==$b and .command==$p' "$1" >/dev/null 2>&1 ;;
  esac
}

upgrade_legacy_updater_timeout() {
  local target tmp updater_count
  [[ "$ACTION" == install && "$session_start_timeout" != 30 && -r "$record" ]] || return 0
  jq -e '.schema=="afk-adapter-install/3" and .phase=="active" and .auto_update==true' "$record" >/dev/null 2>&1 || return 0
  record_identity_valid "$record" && restoration_metadata_valid "$record" || return 0
  case "$HARNESS" in
    claude) target="$HOME_ROOT/.claude/settings.json" ;;
    codex) target="$HOME_ROOT/.codex/hooks.json" ;;
    *) return 0 ;;
  esac
  [[ -f "$target" && ! -L "$target" ]] || return 0
  updater_count="$(jq --arg u "$session_start" '[.hooks.SessionStart[]?.hooks[]?|select(.command==$u)]|length' "$target" 2>/dev/null || true)"
  [[ "$updater_count" == 1 ]] || return 0
  jq -e --arg u "$session_start" 'any(.hooks.SessionStart[]?.hooks[]?; .command==$u and .type=="command" and .timeout==30 and (has("async")|not))' "$target" >/dev/null 2>&1 || return 0
  tmp="${target}.afk-timeout.$$"
  jq --arg u "$session_start" --argjson t "$session_start_timeout" '
    .hooks.SessionStart |= map(.hooks |= map(if .command==$u and .type=="command" and .timeout==30 then .timeout=$t else . end))
  ' "$target" >"$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod --reference="$target" "$tmp" 2>/dev/null || chmod 600 "$tmp"
  mv -f -- "$tmp" "$target"
}
restoration_metadata_valid() { # record
  local prior digest actual
  prior="$(jq -r '.backup // empty' "$1")"; digest="$(jq -r '.backup_sha256 // empty' "$1")"
  [[ -n "$prior" && -n "$digest" && -f "$prior" && ! -L "$prior" ]] || return 1
  actual="$(file_sha256 "$prior" 2>/dev/null)" || return 1
  [[ "$actual" == "$digest" ]] || return 1
  case "$HARNESS" in
    claude)
      jq -e --slurpfile r "$1" '
        type=="object" and (.present|type)=="boolean" and (.hooks_preexisting|type)=="boolean"
        and has("value") and (if .present==false then .value==null else true end)
        and (.hook_groups|keys|sort)==["PreCompact","SessionStart","UserPromptSubmit"]
        and all(.hook_groups[]; type=="boolean")
        and (if .hooks_preexisting==false then all(.hook_groups[]; .==false) else true end)
        and .config_preexisting==$r[0].config_preexisting' "$prior" >/dev/null 2>&1 ;;
    codex)
      jq -e --slurpfile r "$1" '
        type=="object" and (.present|type)=="boolean" and (.config_preexisting|type)=="boolean"
        and (.hooks_preexisting|type)=="boolean" and (.hook_groups|type)=="object"
        and has("value")
        and (if .present then (.value|type)=="array" and all(.value[]; type=="string") else .value==null end)
        and (.hook_groups|keys|sort)==["PreCompact","SessionStart"]
        and all(.hook_groups[]; type=="boolean")
        and (if .hooks_preexisting==false then all(.hook_groups[]; .==false) else true end)
        and .config_preexisting==$r[0].config_preexisting and .hooks_preexisting==$r[0].hooks_preexisting
        and .hook_groups==$r[0].hook_groups' "$prior" >/dev/null 2>&1 ;;
    opencode)
      jq -e --slurpfile r "$1" '
        type=="object" and (.config_preexisting|type)=="boolean" and (.prior_plugin_present|type)=="boolean"
        and .config_preexisting==$r[0].config_preexisting and .prior_plugin_present==$r[0].prior_plugin_present' "$prior" >/dev/null 2>&1 ;;
  esac
}
atomic_json() { # source target
  local source="$1" target="$2" tmp
  tmp="${target}.tmp.$$"
  jq . "$source" >"$tmp"; chmod 600 "$tmp"; mv -f -- "$tmp" "$target"
}
recover_pending_install() {
  local phase
  [[ -r "$record" ]] || return 0
  phase="$(jq -r '.phase // "active"' "$record" 2>/dev/null || true)"
  [[ "$phase" == installing ]] || return 0
  jq -e --arg h "$HARNESS" '.schema=="afk-adapter-install/3" and .harness==$h and .phase=="installing"' "$record" >/dev/null 2>&1 \
    || { printf 'adapter-manager: RECOVERY_RECORD_UNSAFE\n' >&2; exit 3; }
  if ! record_identity_valid "$record" || ! restoration_metadata_valid "$record"; then
    printf 'adapter-manager: RECOVERY_RECORD_UNSAFE\n' >&2; exit 3
  fi
  rollback_pending_install
}
INSTALL_COMMITTED=true
INSTALL_TEMP_FILES=()
rollback_install_on_exit() {
  local rc=$? path
  trap release_manager_lock EXIT
  for path in "${INSTALL_TEMP_FILES[@]}"; do [[ -z "$path" ]] || rm -f -- "$path"; done
  if [[ "$INSTALL_COMMITTED" != true ]]; then recover_pending_install || true; fi
  release_manager_lock
  trap - EXIT
  exit "$rc"
}
jsonc_plugin() { # inspect|install|remove file plugin [prior-present]
  node - "$@" <<'NODE'
const fs = require("node:fs")
const [action, path, plugin, priorText = "false"] = process.argv.slice(2)
const text = fs.readFileSync(path, "utf8")
function withoutComments(source) {
  let out = "", string = false, escape = false
  for (let i = 0; i < source.length; i++) {
    const c = source[i], n = source[i + 1]
    if (string) {
      out += c
      if (escape) escape = false
      else if (c === "\\") escape = true
      else if (c === '"') string = false
    } else if (c === '"') { string = true; out += c }
    else if (c === "/" && n === "/") {
      out += "  "; i++
      while (i + 1 < source.length && source[i + 1] !== "\n") { out += " "; i++ }
    } else if (c === "/" && n === "*") {
      out += "  "; i++
      while (i + 1 < source.length) {
        const x = source[++i], y = source[i + 1]
        if (x === "*" && y === "/") { out += "  "; i++; break }
        out += x === "\n" ? "\n" : " "
      }
    } else out += c
  }
  return out
}
function removeTrailingCommas(source) {
  let out = "", string = false, escape = false
  for (let i = 0; i < source.length; i++) {
    const c = source[i]
    if (string) {
      out += c
      if (escape) escape = false
      else if (c === "\\") escape = true
      else if (c === '"') string = false
      continue
    }
    if (c === '"') { string = true; out += c; continue }
    if (c === ",") {
      let j = i + 1
      while (/\s/.test(source[j] || "")) j++
      if (source[j] === "]" || source[j] === "}") { out += " "; continue }
    }
    out += c
  }
  return out
}
const parsed = JSON.parse(removeTrailingCommas(withoutComments(text)))
if (!parsed || Array.isArray(parsed) || typeof parsed !== "object" ||
    (parsed.plugin !== undefined && (!Array.isArray(parsed.plugin) || !parsed.plugin.every((value) => typeof value === "string")))) process.exit(3)
function skipTrivia(i) {
  while (i < text.length) {
    if (/\s/.test(text[i])) { i++; continue }
    if (text[i] === "/" && text[i + 1] === "/") { i += 2; while (i < text.length && text[i] !== "\n") i++; continue }
    if (text[i] === "/" && text[i + 1] === "*") { i += 2; while (i + 1 < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++; i += 2; continue }
    break
  }
  return i
}
function stringEnd(i) {
  i++
  for (let escape = false; i < text.length; i++) {
    if (escape) escape = false
    else if (text[i] === "\\") escape = true
    else if (text[i] === '"') return i + 1
  }
  throw new Error("unterminated string")
}
function valueEnd(i) {
  let square = 0, curly = 0, string = false, escape = false
  for (; i < text.length; i++) {
    const c = text[i], n = text[i + 1]
    if (string) {
      if (escape) escape = false
      else if (c === "\\") escape = true
      else if (c === '"') string = false
      continue
    }
    if (c === '"') { string = true; continue }
    if (c === "/" && n === "/") { while (i + 1 < text.length && text[i + 1] !== "\n") i++; continue }
    if (c === "/" && n === "*") { i += 2; while (i + 1 < text.length && !(text[i] === "*" && text[i + 1] === "/")) i++; i++; continue }
    if (c === "[") square++
    else if (c === "]") {
      if (square === 0 && curly === 0) return i
      square--; if (square === 0 && curly === 0) return i + 1
    }
    else if (c === "{") curly++
    else if (c === "}") { if (square === 0 && curly === 0) return i; curly-- }
    else if (c === "," && square === 0 && curly === 0) return i
  }
  return i
}
let i = skipTrivia(0)
if (text[i] !== "{") process.exit(3)
i++
const props = []
let closing = -1
while (i < text.length) {
  i = skipTrivia(i)
  if (text[i] === "}") { closing = i; break }
  const keyStart = i, keyEnd = stringEnd(i), key = JSON.parse(text.slice(keyStart, keyEnd))
  i = skipTrivia(keyEnd)
  if (text[i++] !== ":") process.exit(3)
  const start = skipTrivia(i), end = valueEnd(start)
  i = skipTrivia(end)
  const comma = text[i] === "," ? i : null
  props.push({ key, keyStart, start, end, comma })
  if (comma !== null) i++
  else { i = skipTrivia(i); if (text[i] !== "}") process.exit(3) }
}
if (closing < 0) process.exit(3)
const found = props.find((p) => p.key === "plugin")
if (props.filter((p) => p.key === "plugin").length > 1) process.exit(3)
const plugins = parsed.plugin || []
if (action === "inspect") {
  process.stdout.write(JSON.stringify({ prior_present: Object.hasOwn(parsed, "plugin"), contains: plugins.includes(plugin), owned_count: plugins.filter((value) => value === plugin).length, keys: Object.keys(parsed) }) + "\n")
  process.exit(0)
}
let result = text
if (action === "install") {
  if (plugins.includes(plugin)) process.exit(4)
  const replacement = JSON.stringify([...plugins, plugin])
  if (found) {
    const close = found.end - 1
    const body = text.slice(found.start + 1, close)
    const trailing = withoutComments(body).trimEnd().endsWith(",")
    const addition = !plugins.length ? JSON.stringify(plugin) : trailing ? `${JSON.stringify(plugin)},` : `,${JSON.stringify(plugin)}`
    result = text.slice(0, close) + addition + text.slice(close)
  }
  else {
    const last = props[props.length - 1]
    const addition = !props.length ? `"plugin":${replacement}` : last.comma === null ? `,"plugin":${replacement}` : `"plugin":${replacement},`
    result = text.slice(0, closing) + addition + text.slice(closing)
  }
} else if (action === "remove") {
  if (!found || !plugins.includes(plugin)) process.exit(4)
  const close = found.end - 1
  const elements = []
  let p = found.start + 1
  while (p < close) {
    p = skipTrivia(p)
    if (text[p] === "]") break
    const start = p, end = valueEnd(start)
    p = skipTrivia(end)
    const comma = text[p] === "," ? p : null
    elements.push({ start, end, comma, value: JSON.parse(removeTrailingCommas(withoutComments(text.slice(start, end)))) })
    if (comma !== null) p++
  }
  const ownedIndex = elements.findIndex((element) => element.value === plugin)
  if (ownedIndex < 0) process.exit(4)
  const owned = elements[ownedIndex]
  if (elements.length > 1 || priorText === "true") {
    if (owned.comma !== null) result = text.slice(0, owned.start) + text.slice(owned.comma + 1)
    else if (ownedIndex > 0 && elements[ownedIndex - 1].comma !== null) result = text.slice(0, elements[ownedIndex - 1].comma) + text.slice(owned.end)
    else result = text.slice(0, owned.start) + text.slice(owned.end)
  } else {
    const index = props.indexOf(found)
    if (found.comma !== null) result = text.slice(0, found.keyStart) + text.slice(found.comma + 1)
    else if (index > 0 && props[index - 1].comma !== null) result = text.slice(0, props[index - 1].comma) + text.slice(found.end)
    else result = text.slice(0, found.keyStart) + text.slice(found.end)
  }
} else process.exit(2)
process.stdout.write(result)
NODE
}
safe_exact_path() { # observed expected [allow-absent]
  local observed="$1" expected="$2" allow_absent="${3:-false}"
  [[ "$observed" == "$expected" && ! -L "$observed" ]] || return 1
  if [[ "$allow_absent" == true && ! -e "$observed" ]]; then return 0; fi
  [[ -f "$observed" ]]
}
recovery_tmp() { # target
  local target="$1" tmp inode
  tmp="$(mktemp "${target}.afk-recovery.XXXXXX")" || return 1
  [[ "$tmp" == "${target}.afk-recovery."?????? && ! -L "$tmp" && -f "$tmp" \
    && "$(dirname "$tmp")" == "$(dirname "$target")" ]] || return 1
  inode="$(file_id "$tmp")"; [[ -n "$inode" ]] || return 1
  RECOVERY_TMP_PATH="$tmp"; RECOVERY_TMP_INODE="$inode"
}
verify_recovery_tmp() { # temp inode target
  [[ ! -L "$1" && -f "$1" && "$(file_id "$1")" == "$2" \
    && "$(dirname "$1")" == "$(dirname "$3")" ]]
}
claude_pending_safe() { # source owner-record prior-record [require-all]
  jq -e --slurpfile owner "$2" --slurpfile prior "$3" --argjson require_all "${4:-false}" --argjson current_ut "$session_start_timeout" '
    ($owner[0]) as $o
    | (if $prior[0].present and ($prior[0].value|type)=="object"
       then ($prior[0].value | .command=$o.command)
       else {type:"command",command:$o.command,refreshInterval:5} end) as $installed
    | ($o.auto_update // (($o.updater // "") != "")) as $enabled
    | (if $o.schema=="afk-adapter-install/2" then 30 else $current_ut end) as $ut
    | ({hooks:[{type:"command",command:$o.updater,timeout:$ut}]}) as $updater
    | ({matcher:"compact",hooks:[{type:"command",command:$o.instruction,timeout:3}]}) as $instruction
    | ({hooks:[{type:"command",command:$o.compact,timeout:3}]}) as $compact
    | ({hooks:[{type:"command",command:$o.prompt,timeout:3}]}) as $prompt
    | ([.hooks.SessionStart[]? | select(.==$updater)]|length) as $uc
    | ([.hooks.SessionStart[]? | select(.==$instruction)]|length) as $ic
    | ([.hooks.PreCompact[]? | select(.==$compact)]|length) as $cc
    | ([.hooks.UserPromptSubmit[]? | select(.==$prompt)]|length) as $pc
    | ((if $prior[0].present then .statusLine==$prior[0].value else (has("statusLine")|not) end)
       or .statusLine==$installed)
      and ([.hooks.SessionStart[]?
        | select(any(.hooks[]?; ($enabled and .command==$o.updater) or .command==$o.instruction))
        | select((($enabled|not) or .!=$updater) and .!=$instruction)]|length)==0
      and ([.hooks.PreCompact[]?
        | select(any(.hooks[]?; .command==$o.compact))
        | select(.!=$compact)]|length)==0
      and ([.hooks.UserPromptSubmit[]?
        | select(any(.hooks[]?; .command==$o.prompt))
        | select(.!=$prompt)]|length)==0
      and $uc<=(if $enabled then 1 else 0 end) and $ic<=1 and $cc<=1 and $pc<=1
      and (if $require_all then
        $uc==(if $enabled then 1 else 0 end) and $ic==1 and $cc==1 and $pc==1
      else true end)' "$1" >/dev/null 2>&1
}
claude_strip_owned() { # source destination owner-record prior-record
  jq --slurpfile owner "$3" --slurpfile prior "$4" --argjson current_ut "$session_start_timeout" '
    ($owner[0]) as $o
    | ($o.auto_update // (($o.updater // "") != "")) as $enabled
    | (if $o.schema=="afk-adapter-install/2" then 30 else $current_ut end) as $ut
    | ({hooks:[{type:"command",command:$o.updater,timeout:$ut}]}) as $updater
    | ({matcher:"compact",hooks:[{type:"command",command:$o.instruction,timeout:3}]}) as $instruction
    | ({hooks:[{type:"command",command:$o.compact,timeout:3}]}) as $compact
    | ({hooks:[{type:"command",command:$o.prompt,timeout:3}]}) as $prompt
    | (if $prior[0].present then .statusLine=$prior[0].value else del(.statusLine) end)
    | .hooks.SessionStart = [(.hooks.SessionStart // [])[]
        | select((($enabled|not) or .!=$updater) and .!=$instruction)]
    | if (.hooks.SessionStart|length)==0 then
        if ($prior[0].hook_groups.SessionStart // false) then .hooks.SessionStart=[] else del(.hooks.SessionStart) end else . end
    | .hooks.PreCompact = [(.hooks.PreCompact // [])[] | select(.!=$compact)]
    | if (.hooks.PreCompact|length)==0 then
        if ($prior[0].hook_groups.PreCompact // false) then .hooks.PreCompact=[] else del(.hooks.PreCompact) end else . end
    | .hooks.UserPromptSubmit = [(.hooks.UserPromptSubmit // [])[] | select(.!=$prompt)]
    | if (.hooks.UserPromptSubmit|length)==0 then
        if ($prior[0].hook_groups.UserPromptSubmit // false) then .hooks.UserPromptSubmit=[] else del(.hooks.UserPromptSubmit) end else . end
    | if (($prior[0].hooks_preexisting|not) and .hooks=={}) then del(.hooks) else . end' "$1" >"$2"
}
codex_hooks_safe() { # hooks owner-record require-all
  jq -e --slurpfile owner "$2" --argjson require_all "$3" --argjson current_ut "$session_start_timeout" '
    ($owner[0]) as $o
    | ($o.auto_update // (($o.updater // "") != "")) as $enabled
    | (if $o.schema=="afk-adapter-install/2" then 30 else $current_ut end) as $ut
    | ({hooks:[{type:"command",command:$o.updater,timeout:$ut}]}) as $updater
    | ({hooks:[{type:"command",command:$o.command,timeout:3}]}) as $publisher
    | ({matcher:"compact",hooks:[{type:"command",command:$o.instruction,timeout:3}]}) as $instruction
    | ([.hooks.SessionStart[]? | select(.==$updater)]|length) as $uc
    | ([.hooks.SessionStart[]? | select(.==$publisher)]|length) as $pc
    | ([.hooks.SessionStart[]? | select(.==$instruction)]|length) as $ic
    | ([.hooks.PreCompact[]? | select(.==$publisher)]|length) as $cc
    | ([.hooks.SessionStart[]?
        | select(any(.hooks[]?; ($enabled and .command==$o.updater) or .command==$o.command or .command==$o.instruction))
        | select((($enabled|not) or .!=$updater) and .!=$publisher and .!=$instruction)]|length)==0
      and ([.hooks.PreCompact[]?
        | select(any(.hooks[]?; .command==$o.command))
        | select(.!=$publisher)]|length)==0
      and $uc<=(if $enabled then 1 else 0 end) and $pc<=1 and $ic<=1 and $cc<=1
      and (if $require_all then
        $uc==(if $enabled then 1 else 0 end) and $pc==1 and $ic==1 and $cc==1
      else true end)' "$1" >/dev/null 2>&1
}
codex_pending_safe() { # config hooks owner-record prior-record
  local current_status prior_status installed_status
  if [[ -e "$1" ]]; then
    current_status="$(yq -p=toml -o=json '.tui.status_line // null' "$1" 2>/dev/null | jq -c .)" || return 1
    prior_status="$(jq -c '.value // null' "$4")" || return 1
    installed_status="$(jq -c '.installed // null' "$3")" || return 1
    [[ "$installed_status" != null && ( "$current_status" == "$prior_status" || "$current_status" == "$installed_status" ) ]] || return 1
  fi
  [[ ! -e "$2" ]] || codex_hooks_safe "$2" "$3" false
}
legacy_v2_path_matches() { # recorded expected [relative-base]
  local recorded="$1" expected="$2" relative_base="${3:-$INVOCATION_CWD}" candidate_parent expected_parent candidate_name expected_name
  [[ -n "$recorded" && "$recorded" != *$'\n'* && "$recorded" != *$'\r'* && "$recorded" != *$'\t'* ]] || return 1
  [[ "$recorded" == /* ]] || recorded="$relative_base/$recorded"
  candidate_name="$(basename -- "$recorded")"; expected_name="$(basename -- "$expected")"
  [[ "$candidate_name" != . && "$candidate_name" != .. && "$candidate_name" == "$expected_name" ]] || return 1
  candidate_parent="$(cd "$(dirname -- "$recorded")" 2>/dev/null && pwd -P)" || return 1
  expected_parent="$(cd "$(dirname -- "$expected")" 2>/dev/null && pwd -P)" || return 1
  [[ "$candidate_parent/$candidate_name" == "$expected_parent/$expected_name" ]]
}
legacy_v2_adapter_path_matches() { # recorded expected [relative-base]
  local recorded="$1" expected="$2" relative_base="${3:-$INVOCATION_CWD}" component candidate_parent expected_parent candidate_name expected_name
  local -a path_components
  [[ -n "$recorded" && "$recorded" != *$'\n'* && "$recorded" != *$'\r'* && "$recorded" != *$'\t'* ]] || return 1
  IFS=/ read -r -a path_components <<<"$recorded"
  for component in "${path_components[@]}"; do [[ "$component" != .. ]] || return 1; done
  [[ "$recorded" == /* ]] || recorded="$relative_base/$recorded"
  candidate_name="$(basename -- "$recorded")"; expected_name="$(basename -- "$expected")"
  [[ "$candidate_name" != . && "$candidate_name" != .. && "$candidate_name" == "$expected_name" ]] || return 1
  candidate_parent="$(cd "$(dirname -- "$recorded")" 2>/dev/null && pwd -P)" || return 1
  expected_parent="$(cd "$(dirname -- "$expected")" 2>/dev/null && pwd -P)" || return 1
  [[ "$candidate_parent/$candidate_name" == "$expected_parent/$expected_name" \
    && ! -L "$recorded" && -f "$recorded" ]]
}
legacy_v2_adapter_command_matches() { # recorded expected-path fixed-suffix [relative-base]
  local recorded="$1" expected="$2" suffix="$3" relative_base="${4:-$INVOCATION_CWD}" path
  if [[ -n "$suffix" ]]; then
    [[ "$recorded" == *"$suffix" ]] || return 1
    path="${recorded%"$suffix"}"
    [[ -n "$path" && "$path$suffix" == "$recorded" ]] || return 1
  else
    path="$recorded"
  fi
  legacy_v2_adapter_path_matches "$path" "$expected" "$relative_base"
}
legacy_v2_adapter_url_matches() { # recorded expected-path [relative-base]
  local recorded="$1" relative_base="${3:-$INVOCATION_CWD}" path
  [[ "$recorded" == file://* ]] || return 1
  path="${recorded#file://}"
  [[ -n "$path" && "$path" != //* ]] || return 1
  legacy_v2_adapter_path_matches "$path" "$2" "$relative_base"
}
v2_record_identity_valid() { # record
  local target backup hooks command updater compact instruction prompt
  case "$HARNESS" in
    claude)
      jq -e '
        def clean: type=="string" and (explode|all(. >= 32 and . != 127));
        (keys|sort)==["backup","command","compact","harness","instruction","prompt","schema","target","updater"]
        and .schema=="afk-adapter-install/2" and .harness=="claude"
        and all([.target,.backup,.command,.updater,.compact,.instruction,.prompt][]; clean)' "$1" >/dev/null 2>&1 || return 1 ;;
    codex)
      jq -e '
        def clean: type=="string" and (explode|all(. >= 32 and . != 127));
        (keys|sort)==["backup","command","harness","hook_groups","hooks","hooks_preexisting","installed","instruction","schema","target","updater"]
        and .schema=="afk-adapter-install/2" and .harness=="codex"
        and all([.target,.hooks,.backup,.command,.updater,.instruction][]; clean)
        and (.hooks_preexisting|type)=="boolean"
        and (.hook_groups|keys|sort)==["PreCompact","SessionStart"]
        and all(.hook_groups[]; type=="boolean") and (.installed|type)=="array"
        and all(.installed[]; type=="string")
        and (if .hooks_preexisting==false then all(.hook_groups[]; .==false) else true end)' "$1" >/dev/null 2>&1 || return 1 ;;
    opencode)
      jq -e '
        def clean: type=="string" and (explode|all(. >= 32 and . != 127));
        (keys|sort)==["command","harness","prior_plugin_present","schema","target"]
        and .schema=="afk-adapter-install/2" and .harness=="opencode"
        and all([.target,.command][]; clean)
        and (.prior_plugin_present|type)=="boolean"' "$1" >/dev/null 2>&1 || return 1 ;;
  esac
  target="$(jq -r .target "$1")"
  case "$HARNESS" in
    claude)
      backup="$(jq -r .backup "$1")"
      command="$(jq -r .command "$1")"; updater="$(jq -r .updater "$1")"
      compact="$(jq -r .compact "$1")"; instruction="$(jq -r .instruction "$1")"; prompt="$(jq -r .prompt "$1")"
      legacy_v2_path_matches "$target" "$HOME_ROOT/.claude/settings.json" || return 1
      legacy_v2_path_matches "$backup" "$STATE_DIR/adapters/claude-prior.json" || return 1
      legacy_v2_adapter_command_matches "$command" "$ADAPTER_ROOT/claude/statusline.sh" "" || return 1
      legacy_v2_adapter_command_matches "$updater" "$session_start" "" || return 1
      legacy_v2_adapter_command_matches "$compact" "$ADAPTER_ROOT/worker-context.sh" " compact --harness claude" || return 1
      legacy_v2_adapter_command_matches "$instruction" "$ADAPTER_ROOT/worker-context.sh" " session-start --harness claude" || return 1
      legacy_v2_adapter_command_matches "$prompt" "$ADAPTER_ROOT/worker-context.sh" " prompt-boundary --harness claude" ;;
    codex)
      backup="$(jq -r .backup "$1")"; hooks="$(jq -r .hooks "$1")"
      command="$(jq -r .command "$1")"; updater="$(jq -r .updater "$1")"; instruction="$(jq -r .instruction "$1")"
      legacy_v2_path_matches "$target" "$HOME_ROOT/.codex/config.toml" || return 1
      legacy_v2_path_matches "$hooks" "$HOME_ROOT/.codex/hooks.json" || return 1
      legacy_v2_path_matches "$backup" "$STATE_DIR/adapters/codex-prior.json" || return 1
      legacy_v2_adapter_command_matches "$command" "$ADAPTER_ROOT/codex/publish.sh" "" || return 1
      legacy_v2_adapter_command_matches "$updater" "$session_start" "" || return 1
      legacy_v2_adapter_command_matches "$instruction" "$ADAPTER_ROOT/worker-context.sh" " session-start --harness codex" ;;
    opencode)
      command="$(jq -r .command "$1")"
      { legacy_v2_path_matches "$target" "$HOME_ROOT/.config/opencode/opencode.json" \
        || legacy_v2_path_matches "$target" "$HOME_ROOT/.config/opencode/opencode.jsonc"; } || return 1
      legacy_v2_adapter_url_matches "$command" "$ADAPTER_ROOT/opencode/plugin.js" ;;
  esac
}
migration_conflict() { printf 'adapter-manager: USER_CONFIG_CONFLICT\n' >&2; exit 3; }
migration_recovery_conflict() { printf 'adapter-manager: RECOVERY_VERIFICATION_FAILED\n' >&2; exit 3; }
