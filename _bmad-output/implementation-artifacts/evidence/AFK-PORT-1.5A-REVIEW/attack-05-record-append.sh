#!/usr/bin/env bash
# ATTACK 5 — the record append: placement, idempotence, inode/permissions,
# frontmatter and gates untouched, EOF whitespace, concurrency.
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
T="$(mktemp -d /tmp/afk15a-rec.XXXXXX)"
# Source only the pure/file halves of dispatch.sh; main() is not invoked.
TMPFILES=(); . "$DISPATCH" 2>/dev/null || true
log() { :; }   # silence

mk() { printf '%s' "$1" > "$T/$2"; }

# --- 5a. Dev Agent Record is the LAST section -----------------------------
cat > "$T/last.md" <<'MD'
---
persona: dev
gates: ["true"]
---

# Story

Body.

## Dev Agent Record

existing note
MD
cp "$T/last.md" "$T/last.orig.md"
INODE_BEFORE="$(stat -c %i "$T/last.md")"; chmod 0640 "$T/last.md"
PERM_BEFORE="$(stat -c %a "$T/last.md")"
record_sizing_risk "$T/last.md" 100 200 0.500000 1
eq "5a: inode preserved"      "$(stat -c %i "$T/last.md")" "$INODE_BEFORE"
eq "5a: permissions preserved" "$(stat -c %a "$T/last.md")" "$PERM_BEFORE"
eq "5a: exactly one finding line" "$(grep -ac '^- budget: SIZING_RISK' "$T/last.md")" "1"
has "5a: line is after the heading" "$(sed -n '/^## Dev Agent Record/,$p' "$T/last.md")" "- budget: SIZING_RISK"
has "5a: existing content preserved" "$(cat "$T/last.md")" "existing note"
eq "5a: frontmatter byte-identical" \
   "$(sed -n '1,4p' "$T/last.md" | sha256sum)" "$(sed -n '1,4p' "$T/last.orig.md" | sha256sum)"
# order: the new line comes AFTER the pre-existing note
LN_NOTE="$(grep -n 'existing note' "$T/last.md" | cut -d: -f1)"
LN_BUD="$(grep -n '^- budget:' "$T/last.md" | cut -d: -f1)"
[[ "$LN_BUD" -gt "$LN_NOTE" ]] && ok "5a: appended at the END of the section" || bad "5a: appended at the END of the section" "note=$LN_NOTE bud=$LN_BUD"

# --- 5b. Dev Agent Record FOLLOWED by another '## ' heading ---------------
cat > "$T/mid.md" <<'MD'
---
persona: dev
---

## Dev Agent Record

note one

## Afterwards

trailing section
MD
record_sizing_risk "$T/mid.md" 100 200 0.500000 1
LN_BUD="$(grep -n '^- budget:' "$T/mid.md" | cut -d: -f1)"
LN_AFT="$(grep -n '^## Afterwards' "$T/mid.md" | cut -d: -f1)"
LN_ONE="$(grep -n 'note one' "$T/mid.md" | cut -d: -f1)"
if [[ "$LN_BUD" -gt "$LN_ONE" && "$LN_BUD" -lt "$LN_AFT" ]]; then
  ok "5b: inserted inside the section, before the next '## ' heading"
else bad "5b: inserted inside the section, before the next '## ' heading" "one=$LN_ONE bud=$LN_BUD aft=$LN_AFT"; fi
has "5b: the following section survives" "$(cat "$T/mid.md")" "trailing section"

# --- 5c. no Dev Agent Record heading at all ------------------------------
printf -- '---\npersona: dev\n---\n\nBody only.\n' > "$T/none.md"
record_sizing_risk "$T/none.md" 100 200 0.500000 1
has "5c: heading created rather than the finding dropped" "$(cat "$T/none.md")" "## Dev Agent Record"
eq "5c: exactly one finding line" "$(grep -ac '^- budget:' "$T/none.md")" "1"

# --- 5d. idempotence per cycle -------------------------------------------
for i in 1 2 3; do record_sizing_risk "$T/last.md" 100 200 0.500000 1; done
eq "5d: three re-dispatches of cycle 1 leave ONE line" "$(grep -ac '^- budget:' "$T/last.md")" "1"
record_sizing_risk "$T/last.md" 100 200 0.500000 2
eq "5d: a new cycle earns its own line" "$(grep -ac '^- budget:' "$T/last.md")" "2"
record_sizing_risk "$T/last.md" 100 200 0.500000 10
eq "5d: cycle 10 is not confused with cycle 1" "$(grep -ac '^- budget:' "$T/last.md")" "3"
record_sizing_risk "$T/last.md" 100 200 0.500000 10
eq "5d: and cycle 10 is itself idempotent" "$(grep -ac '^- budget:' "$T/last.md")" "3"

# --- 5e. EOF whitespace / no trailing newline ----------------------------
printf -- '---\npersona: dev\n---\n\n## Dev Agent Record\n\nno trailing newline' > "$T/eof.md"
record_sizing_risk "$T/eof.md" 100 200 0.500000 1
eq "5e: a story with no trailing newline still gets exactly one line" \
   "$(grep -ac '^- budget:' "$T/eof.md")" "1"
[[ "$(tail -c1 "$T/eof.md" | xxd -p)" == "0a" ]] && ok "5e: file ends with a newline afterwards" \
  || bad "5e: file ends with a newline afterwards" "$(tail -c1 "$T/eof.md" | xxd -p)"
printf '     (info) eof.md tail:\n'; tail -3 "$T/eof.md" | sed 's/^/       | /'

# --- 5f. a '## ' line inside a FENCED CODE BLOCK in the record -----------
cat > "$T/fence.md" <<'MD'
---
persona: dev
---

## Dev Agent Record

Example output:

```
## this is sample markdown inside a fence
```

after the fence
MD
record_sizing_risk "$T/fence.md" 100 200 0.500000 1
LN_BUD="$(grep -n '^- budget:' "$T/fence.md" | cut -d: -f1)"
LN_FENCE="$(grep -n 'sample markdown inside a fence' "$T/fence.md" | cut -d: -f1)"
printf '     (info) fenced-heading case: budget line %s, fenced ## line %s\n' "$LN_BUD" "$LN_FENCE"
if [[ "$LN_BUD" -lt "$LN_FENCE" ]]; then
  bad "5f: a '## ' line inside a code fence is treated as the next heading" \
      "the finding was inserted BEFORE the fence, mid-section"
else ok "5f: a fenced '## ' line does not truncate the section"; fi

# --- 5g. gates list and frontmatter are never touched --------------------
cat > "$T/fm.md" <<'MD'
---
persona: dev
gates:
  - "bash tests/x.sh"
max_cycles: 3
---

## Dev Agent Record

x
MD
B="$(sed -n '/^---$/,/^---$/p' "$T/fm.md" | sha256sum)"
record_sizing_risk "$T/fm.md" 100 200 0.500000 1
eq "5g: frontmatter (incl. gates) byte-identical after the append" \
   "$(sed -n '/^---$/,/^---$/p' "$T/fm.md" | sha256sum)" "$B"

# --- 5h. concurrency is covered by attack-05b (quantified, with a serial
#          control); running it inline here truncated this script's own output.

summary
