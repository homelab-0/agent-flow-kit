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
elif [[ -f "$AFK_IMPORT_LOG.refuse" ]] && jq -e --arg k "bmad-key: $(cat "$AFK_IMPORT_LOG.refuse")" \
    '(.description // "") | split("\n") | index($k) != null' <<<"$data" >/dev/null 2>&1; then
  # The tracker refuses the card whose bmad key is named in the .refuse file.
  printf '{"error":"refused"}500'
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

# Each scenario below gets its own request log, and so its own issue list.
fresh_log() { export AFK_IMPORT_LOG="$TMP/log/$1.jsonl"; : > "$AFK_IMPORT_LOG"; }
import() { afk_bmad_import_backlog "https://paperclip.example" "k" "co" "proj" "spektacle" "$1" 0; }
# The bmad key line of each card the importer asked the tracker to create,
# all of them or only one kind.
posted_keys() {
  jq -rs --arg kind "${1:-}" '[.[] | select(.method=="POST") | .body.description
    | select($kind == "" or contains("kind: " + $kind)) | split("\n")[0]] | join(", ")' "$AFK_IMPORT_LOG"
}

# With ten or more epics, "epic-1" is also the start of "epic-10". Only the
# epic-10 card exists, and the tracker hands its description back with CRLF.
mkdir -p "$TMP/ten/_bmad-output/implementation-artifacts"
cat > "$TMP/ten/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'EOF'
development_status:
  epic-1: backlog
  1-1-first-story: backlog
  epic-10: backlog
EOF
fresh_log ten
cat > "$AFK_IMPORT_LOG.issues" <<'EOF'
[{"id":"card-epic-10","description":"bmad-key: epic-10\r\ntracker-status: backlog\r\nkind: epic\r\n"}]
EOF
import "$TMP/ten" >/dev/null
assert_eq "A card is found by its whole key, so a missing epic-1 is not taken for epic-10" \
  "$(posted_keys)" \
  "bmad-key: epic-1, bmad-key: 1-1-first-story"
assert_eq "A story goes under its own epic when another epic's key starts the same way" \
  "$(jq -rs '[.[] | select(.method=="POST") | .body.parentId // empty] | join(", ")' "$AFK_IMPORT_LOG")" \
  "issue-1"

# The tracker refuses the epic-1 card. Its stories must not be created without
# a parent, because a later pass would find them and leave them that way.
fresh_log refused
printf 'epic-1' > "$AFK_IMPORT_LOG.refuse"
out="$(import "$TMP/repo")"
assert_eq "When an epic card cannot be created, its stories wait and the other epics go ahead" \
  "$(jq -r '.created' <<<"$out") created, stories: $(posted_keys story)" \
  "2 created, stories: bmad-key: 2-1-create-the-repository"
# The next pass sees every card the tracker accepted, and epic-1 now goes through.
seen="$(jq -cs '[.[] | select(.method=="POST") | .body
  | select(.description | startswith("bmad-key: epic-1\n") | not)
  | {id: .idempotencyKey, description}]' "$AFK_IMPORT_LOG")"
fresh_log refused-next
printf '%s\n' "$seen" > "$AFK_IMPORT_LOG.issues"
import "$TMP/repo" >/dev/null
assert_eq "The next pass creates that epic and puts its waiting stories under it" \
  "$(posted_keys) under $(jq -rs '[.[] | select(.method=="POST") | .body.parentId // "nothing"] | join(", ")' "$AFK_IMPORT_LOG")" \
  "bmad-key: epic-1, bmad-key: 1-1-record-the-authorization, bmad-key: 1-2-build-the-harness under nothing, issue-1, issue-1"

# A sprint-status file as people edit it: comments and quotes after a status,
# another top-level section after the block, and second-level epic headings.
mkdir -p "$TMP/edited/_bmad-output/planning-artifacts" "$TMP/edited/_bmad-output/implementation-artifacts"
cat > "$TMP/edited/_bmad-output/planning-artifacts/epics.md" <<'EOF'
## Epic 1: Sign in
EOF
cat > "$TMP/edited/_bmad-output/implementation-artifacts/sprint-status.yaml" <<'EOF'
# development_status: one line for each epic and story
project: edited
development_status:
  # Epic 1
  epic-1: in-progress   # started
  1-1-user-auth: done   # merged in #12
  1-2-login: "done"
  1-3-logout: 'done'
  1-4-reset: backlog

# Kept for the record.
archive:
  epic-9: done
  9-1-old-thing: done
EOF
plan="$(afk_bmad_import_plan "$TMP/edited")"
assert_eq "A done status followed by a comment or wrapped in quotes is still done" \
  "$(jq -r '[.[] | select(.epic=="epic-1" and .kind=="story") | "\(.key | split("-")[1])=\(.status)/\(.tracker)"] | join(" ")' <<<"$plan")" \
  "1=done/done 2=done/done 3=done/done 4=backlog/backlog"
assert_eq "Only the development_status block is read, not the sections after it" \
  "$(jq -r '[.[] | .key] | join(" ")' <<<"$plan")" \
  "epic-1 1-1-user-auth 1-2-login 1-3-logout 1-4-reset"
assert_eq "An epic title is read from a second-level heading" \
  "$(jq -r '.[] | select(.key=="epic-1") | .title' <<<"$plan")" \
  "Epic 1: Sign in"

# jq is made to fail while it builds the request body for one story. The
# stand-in lives only in this subshell; the curl stub keeps the real jq.
fresh_log broken-body
out="$(
  jq() {
    if [[ "$*" == *idempotencyKey* && "$*" == *"1.2 build the harness"* ]]; then
      return 2
    fi
    command jq "$@"
  }
  import "$TMP/repo"
)"
assert_eq "A card whose request body cannot be built is left out, and no empty request is sent" \
  "$(jq -r '.created' <<<"$out") created, $(jq -s '[.[] | select(.method=="POST" and (.body | type) != "object")] | length' "$AFK_IMPORT_LOG") empty" \
  "4 created, 0 empty"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
