#!/usr/bin/env bash
# Epics and stories in _bmad-output become unassigned backlog cards.
set -uo pipefail
KIT_ROOT="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0 FAIL=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; FAIL=$((FAIL+1)); }
assert_eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1" "expected '$3', got '$2'"; fi; }

mkdir -p "$TMP/repo/_bmad-output/planning-artifacts" "$TMP/repo/_bmad-output/implementation-artifacts" "$TMP/log"
cat > "$TMP/repo/_bmad-output/planning-artifacts/epics.md" <<'EOF'
### Epic 1: Answer the unknowns
### Epic 2: Install the plane
EOF
cat > "$TMP/repo/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'EOF'
development_status:
  epic-1: backlog
  1-1-record-the-authorization: backlog
  1-2-build-the-harness: done
  epic-1-retrospective: optional
  epic-2: in-progress
  2-1-create-the-repository: backlog
EOF

export AFK_STATE_DIR="$TMP/state"
export AFK_CURL_BIN="$TMP/curl"
export AFK_IMPORT_LOG="$TMP/log/requests.jsonl"
mkdir -p "$AFK_STATE_DIR"
: > "$AFK_IMPORT_LOG"
cat > "$AFK_CURL_BIN" <<'SH'
#!/usr/bin/env bash
method="GET"; url=""; data=""
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    --data|--data-binary|--data-raw|-d)
      if [[ "${2:-}" == @* ]]; then data="$(cat -- "${2#@}" 2>/dev/null || true)"; else data="${2:-}"; fi
      shift 2 ;;
    http*://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
jq -cn --arg m "$method" --arg u "$url" --arg d "$data" \
  '{method:$m, url:$u, body:(try ($d|fromjson) catch $d)}' >> "$AFK_IMPORT_LOG"
if [[ "$method" == GET ]]; then
  if [[ -f "$AFK_IMPORT_LOG.issues" ]]; then
    printf '%s200' "$(cat "$AFK_IMPORT_LOG.issues")"
  else
    printf '[]200'
  fi
else
  n="$(jq -s 'map(select(.method=="POST")) | length' "$AFK_IMPORT_LOG")"
  printf '{"id":"issue-%s","status":"backlog"}201' "$n"
fi
SH
chmod +x "$AFK_CURL_BIN"
# shellcheck disable=SC1091
. "$KIT_ROOT/lib/afk-paperclip.sh"
. "$KIT_ROOT/lib/afk-bmad-import.sh"

plan="$(afk_bmad_import_plan "$TMP/repo")"
assert_eq "The plan has two epics and three stories, and skips the retrospective" \
  "$(jq -r '[.[] | .kind] | group_by(.) | map("\(.[0]):\(length)") | join(",")' <<<"$plan")" \
  "epic:2,story:3"
assert_eq "A done story is marked done and stays tied to its epic" \
  "$(jq -r '.[] | select(.key=="1-2-build-the-harness") | "\(.status):\(.epic)"' <<<"$plan")" \
  "done:epic-1"

out="$(afk_bmad_import_backlog "https://paperclip.example" "k" "co" "proj" "spektacle" "$TMP/repo" 0)"
assert_eq "Every planned card is created once" "$(jq -r '.created' <<<"$out")" "5"
parent_line="$(jq -rs '[.[] | select(.method=="POST" and (.body.description|type)=="string" and (.body.description|contains("kind: story")))] | .[0].body | "\(.parentId|startswith("issue-")):\(.assigneeAgentId // "none")"' "$AFK_IMPORT_LOG")"
parent_line="${parent_line//\"/}"
assert_eq "Stories name their epic as parent and stay unassigned" "$parent_line" "true:none"
# Second pass sees the created descriptions.
jq -s '[.[] | select(.method=="POST") | {id:.body.idempotencyKey, description:.body.description}]' "$AFK_IMPORT_LOG" > "$AFK_IMPORT_LOG.issues"
# The mock GET returns that file as the issue list, but ids are idempotency keys.
# Rewrite into the shape the importer searches.
jq '[.[] | {id, description}]' "$AFK_IMPORT_LOG.issues" > "$AFK_IMPORT_LOG.issues.tmp" && mv "$AFK_IMPORT_LOG.issues.tmp" "$AFK_IMPORT_LOG.issues"
out2="$(afk_bmad_import_backlog "https://paperclip.example" "k" "co" "proj" "spektacle" "$TMP/repo" 0)"
assert_eq "A second import creates nothing new" "$(jq -r '.created' <<<"$out2")" "0"

mkdir -p "$TMP/other/notes/scoped/planning-artifacts" "$TMP/other/notes/scoped/implementation-artifacts"
cp "$TMP/repo/_bmad-output/planning-artifacts/epics.md" "$TMP/other/notes/scoped/planning-artifacts/epics.md"
cp "$TMP/repo/_bmad-output/implementation-artifacts/sprint-status.yaml" "$TMP/other/notes/scoped/implementation-artifacts/sprint-status.yaml"
assert_eq "A configured scope path is read, and the default path is not assumed" \
  "$(afk_bmad_import_plan "$TMP/other" "notes/scoped" | jq -r 'length'):$(afk_bmad_import_plan "$TMP/other" | jq -r 'length')" \
  "5:0"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
