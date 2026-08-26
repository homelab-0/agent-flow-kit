#!/usr/bin/env bash
# A7 — a DETERMINISTIC F6-R2 detector that needs NO in-process interception:
# the marker's own judge reads it with jq, and that fork is a real external
# window. A jq ahead of the real one carries the lock (and the marker inside
# it) away on exactly that read, which is what the winning reclaimer's rename
# does. Everything else is the unmodified library, driven from outside.
set -uo pipefail
KIT="${1:-/home/devbox/repos/jlengelbrecht/agent-flow-kit}"; CTL="$KIT/tests/lockctl-helper.sh"
kv(){ printf '%s\n' "$1"|awk -F= -v k="$2" '$1==k{sub(/^[^=]*=/,"");print;exit}'; }
R=$(mktemp -d); S="$R/state"; mkdir -p "$S"; chmod 700 "$S"; L="$S/lock"
trap 'rm -rf "$R"' EXIT
INC=$(kv "$("$CTL" "$KIT" "$S" strand)" inc)
"$CTL" "$KIT" "$S" strand-marker "$INC" >/dev/null      # a foreign reclaimer owns the marker
BIN="$R/bin"; mkdir -p "$BIN"
cat > "$BIN/jq" <<'SHIM'
#!/usr/bin/env bash
[[ "$X_REAL_JQ" != "${BASH_SOURCE[0]}" ]] || { echo recursion >&2; exit 97; }
if [[ -n "${X_MARKER:-}" && "${*: -1}" == "$X_MARKER" && ! -e "$X_FLAG" ]]; then
  : > "$X_FLAG"
  mv -- "$X_LOCK" "$X_LOCK.handover" 2>/dev/null
  rm -rf -- "$X_LOCK.handover" 2>/dev/null
fi
exec "$X_REAL_JQ" "$@"
SHIM
chmod 755 "$BIN/jq"
export X_REAL_JQ="$(command -v jq)" X_MARKER="$L/reclaim.$INC.json" X_LOCK="$L" X_FLAG="$R/fired"
OUT="$( PATH="$BIN:$PATH" "$CTL" "$KIT" "$S" acquire )"
echo "  fired=$([[ -e "$R/fired" ]] && echo yes || echo no)"
printf '%s\n' "$OUT" | sed 's/^/  /'
