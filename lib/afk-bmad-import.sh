#!/usr/bin/env bash
# afk-bmad-import.sh — copy epics and stories from _bmad-output onto a
# Paperclip backlog. Cards are unassigned and stay in backlog, so the
# factory does not build them until someone moves one to Todo.
if [[ -n "${AFK_BMAD_IMPORT_SOURCED:-}" ]]; then
  return 0
fi
AFK_BMAD_IMPORT_SOURCED=1

afk_bmad_import_plan() { # <repo> [scope_rel]  prints a JSON array of epic then story rows
  local repo="$1" scope="${2:-_bmad-output}"
  [[ "$scope" == /* || "$scope" == *".."* ]] && scope="_bmad-output"
  python3 - "$repo" "$scope" <<'PY'
import json, re, sys
from pathlib import Path
repo = Path(sys.argv[1])
scope = sys.argv[2] if len(sys.argv) > 2 and sys.argv[2] else "_bmad-output"
root = repo / scope
status = root / "implementation-artifacts/sprint-status.yaml"
epics_md = root / "planning-artifacts/epics.md"
if not status.is_file():
    print("[]")
    raise SystemExit(0)
text = status.read_text(errors="replace")
if "development_status:" not in text:
    print("[]")
    raise SystemExit(0)
def scalar(val):
    # A status is one word, but YAML lets it be quoted or followed by a
    # comment. Left in, either would make a done story look unfinished.
    val = val.strip()
    if val[:1] in ("'", '"'):
        end = val.find(val[0], 1)
        if end > 0:
            return val[1:end].strip()
    return re.sub(r"(^|\s)#.*$", "", val).strip()
rows = []
base = None
for raw in text.splitlines():
    line = raw.strip()
    indent = len(raw) - len(raw.lstrip())
    if base is None:
        # Only the key itself opens the block. The name alone can also turn
        # up in a comment above it.
        if re.match(r"\s*development_status\s*:", raw):
            base = indent
        continue
    if not line or line.startswith("#"):
        continue
    if indent <= base:
        # A key at the block's own level ends it. What follows is some other
        # section, and its entries are not cards.
        break
    if ":" not in line:
        continue
    key, val = line.split(":", 1)
    key, val = key.strip(), scalar(val)
    if key.startswith("epic-") and key.endswith("-retrospective"):
        continue
    if key.startswith("epic-") or re.match(r"^\d+-\d+", key):
        rows.append((key, val))
titles = {}
if epics_md.is_file():
    for line in epics_md.read_text(errors="replace").splitlines():
        # Epics are second-level headings in some epics.md files and
        # third-level in others.
        m = re.match(r"^#{2,3} Epic (\d+):\s*(.+)$", line.strip())
        if m:
            titles[f"epic-{m.group(1)}"] = m.group(2).strip()
out = []
for key, tracker in rows:
    if key.startswith("epic-"):
        num = key.split("-", 1)[1]
        title = titles.get(key) or key
        out.append({
            "kind": "epic",
            "key": key,
            "epic": key,
            "title": f"Epic {num}: {title}"[:300],
            "tracker": tracker,
            "status": "backlog",
        })
    else:
        parts = key.split("-", 2)
        epic = f"epic-{parts[0]}"
        label = parts[2].replace("-", " ") if len(parts) > 2 else key
        title = f"{parts[0]}.{parts[1]} {label}"
        status_pc = "done" if tracker == "done" else "backlog"
        out.append({
            "kind": "story",
            "key": key,
            "epic": epic,
            "title": title[:300],
            "tracker": tracker,
            "status": status_pc,
        })
print(json.dumps(out))
PY
}

# afk_bmad_import_backlog <api> <key> <company> <project> <slug> <repo> [limit] [scope_rel]
# limit 0 means import every missing card. scope_rel defaults to _bmad-output.
# Prints a JSON summary.
afk_bmad_import_backlog() {
  local api="${1:-}" key="${2:-}" company="${3:-}" project="${4:-}" slug="${5:-}" repo="${6:-}" limit="${7:-20}" scope="${8:-_bmad-output}"
  [[ -n "$api" && -n "$key" && -n "$company" && -n "$project" && -d "$repo" ]] || return 0
  [[ -n "$scope" ]] || scope="_bmad-output"
  local plan existing resp body
  plan="$(afk_bmad_import_plan "$repo" "$scope")"
  [[ "$(jq -r 'length' <<<"$plan" 2>/dev/null || echo 0)" -gt 0 ]] || {
    printf '{"created":0,"skipped":0}\n'
    return 0
  }
  resp="$(afk_pc_curl GET "$api/api/companies/$company/issues?projectId=$project" "$key" "")"
  [[ "${resp%%$'\n'*}" == 2?? ]] || return 0
  body="${resp#*$'\n'}"
  existing="$(jq -c '
    [ (if type=="array" then . else (.issues // []) end)[]
      | {id, description: (.description // "")} ]
  ' <<<"$body" 2>/dev/null || printf '[]')"
  local created=0 skipped=0 labels_ok=1
  local -A ids=() epics=()
  local row kind bkey title tracker status epic parent idem desc payload code made id next
  # The epics this plan names. A story of one of them is only created once
  # that epic's card id is known.
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    epics["$row"]=1
  done < <(jq -r '.[] | select(.kind == "epic") | .key' <<<"$plan")
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    kind="$(jq -r '.kind' <<<"$row")"
    bkey="$(jq -r '.key' <<<"$row")"
    title="$(jq -r '.title' <<<"$row")"
    tracker="$(jq -r '.tracker' <<<"$row")"
    status="$(jq -r '.status' <<<"$row")"
    epic="$(jq -r '.epic' <<<"$row")"
    # Match the whole key line: "bmad-key: epic-1" is also the start of
    # "bmad-key: epic-10". Only blanks may follow the key, because the tracker
    # may hand a description back with CRLF line ends.
    id="$(jq -r --arg k "bmad-key: ${bkey}" '
      ($k | length) as $n
      | [.[] | select(any(.description | strings | split("\n")[];
            startswith($k) and (.[$n:] | explode | all(. == 32 or . == 9 or . == 13))))
         | .id][0] // empty
    ' <<<"$existing")"
    if [[ -n "$id" ]]; then
      ids["$bkey"]="$id"
      skipped=$((skipped + 1))
      continue
    fi
    if [[ "$limit" != "0" && "$created" -ge "$limit" ]]; then
      break
    fi
    parent=""
    if [[ "$kind" == "story" ]]; then
      parent="${ids[$epic]:-}"
      # The epic is in the plan but has no card yet in this pass: creating it
      # failed, or it comes later in the file. A story created now would have
      # no parent and no later pass would give it one, so it waits for the
      # pass after the epic's card exists.
      [[ -n "$parent" || -z "${epics[$epic]:-}" ]] || continue
    fi
    idem="bmad:${slug}:${bkey}"
    idem="${idem:0:200}"
    desc="$(printf 'bmad-key: %s\ntracker-status: %s\nkind: %s\nImported from _bmad-output. Move this card to Todo when it should be built.\n' "$bkey" "$tracker" "$kind")"
    payload="$(jq -cn \
      --arg t "$title" --arg d "$desc" --arg s "$status" --arg p "$project" \
      --arg parent "$parent" --arg idem "$idem" --arg kind "$kind" \
      --argjson labels_ok "$labels_ok" \
      '{title:$t, description:$d, status:$s, projectId:$p, idempotencyKey:$idem}
       + (if $parent != "" then {parentId:$parent} else {} end)
       + (if $labels_ok == 1 then {labels: ["bmad-"+$kind]} else {} end)')" || payload=""
    # No body means jq failed. Posting nothing would be answered with an
    # error, and that error would be read below as the tracker refusing labels.
    [[ -n "$payload" ]] || continue
    resp="$(afk_pc_curl POST "$api/api/companies/$company/issues" "$key" "" "$payload")"
    code="${resp%%$'\n'*}"
    if [[ "$code" != 2?? && "$labels_ok" == 1 ]]; then
      labels_ok=0
      payload="$(jq -cn \
        --arg t "$title" --arg d "$desc" --arg s "$status" --arg p "$project" \
        --arg parent "$parent" --arg idem "$idem" \
        '{title:$t, description:$d, status:$s, projectId:$p, idempotencyKey:$idem}
         + (if $parent != "" then {parentId:$parent} else {} end)')" || payload=""
      [[ -n "$payload" ]] || continue
      resp="$(afk_pc_curl POST "$api/api/companies/$company/issues" "$key" "" "$payload")"
      code="${resp%%$'\n'*}"
    fi
    [[ "$code" == 2?? ]] || continue
    made="$(jq -r '.id // empty' <<<"${resp#*$'\n'}" 2>/dev/null)"
    [[ -n "$made" ]] || continue
    ids["$bkey"]="$made"
    # Keep the old list if this fails. An empty list would make every later
    # card look missing, and each would be created a second time.
    next="$(jq -c --arg id "$made" --arg d "$desc" '. + [{id:$id, description:$d}]' <<<"$existing" 2>/dev/null)" || next=""
    [[ -z "$next" ]] || existing="$next"
    created=$((created + 1))
  done < <(jq -c '.[]' <<<"$plan")
  jq -cn --argjson c "$created" --argjson s "$skipped" '{created:$c, skipped:$s}'
}
