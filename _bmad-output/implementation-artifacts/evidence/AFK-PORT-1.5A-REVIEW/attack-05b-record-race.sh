#!/usr/bin/env bash
# ATTACK 5b — record_sizing_risk under concurrent dispatches of the same story.
# The append is a read-modify-write (awk to a temp, then `cat tmp > story` to
# preserve the inode) with no lock, so two dispatches that reach it together
# interleave. Quantified rather than asserted, with a serial control.
set -uo pipefail
. "$(dirname "$0")/attack-harness.sh"
TMPFILES=(); . "$DISPATCH" 2>/dev/null || true
log(){ :; }
T="$(mktemp -d /tmp/afk15a-race.XXXXXX)"
mkstory() { printf -- '---\npersona: dev\ngates: ["x"]\n---\n\nBODY-SENTINEL\n\n## Dev Agent Record\n\nexisting note\n' > "$1"; }

# CONTROL — serially, the same calls are correct and idempotent.
mkstory "$T/seq.md"
for c in 1 1 2 2 3; do record_sizing_risk "$T/seq.md" 100 200 0.500000 "$c"; done
eq "5b CONTROL: serial calls give one line per distinct cycle" "$(grep -ac '^- budget:' "$T/seq.md")" "3"
eq "5b CONTROL: serial calls preserve the body"                "$(grep -ac 'BODY-SENTINEL' "$T/seq.md")" "1"

trials=30
for n in 2 8; do
  lost=0; damaged=0
  for t in $(seq $trials); do
    mkstory "$T/r.md"; sz0=$(wc -c < "$T/r.md")
    for c in $(seq "$n"); do ( record_sizing_risk "$T/r.md" 100 200 0.500000 "$c" ) >/dev/null 2>&1 & done
    wait
    l=$(grep -ac '^- budget:' "$T/r.md" || true)
    b=$(grep -ac 'BODY-SENTINEL' "$T/r.md" || true)
    f=$(grep -ac '^gates: \["x"\]' "$T/r.md" || true)
    [[ "$l" == "$n" ]] || lost=$((lost+1))
    { [[ "$b" == "1" && "$f" == "1" ]] && [[ "$(wc -c < "$T/r.md")" -ge "$sz0" ]]; } || damaged=$((damaged+1))
  done
  printf '     (info) %s-way concurrent cycles, %s trials: lost-update in %s, story CONTENT damaged in %s\n' \
    "$n" "$trials" "$lost" "$damaged"
  if (( lost == 0 && damaged == 0 )); then ok "5b: $n concurrent cycles are serialised"
  else bad "5b: $n concurrent cycles race — the append is an unlocked read-modify-write" \
           "lost-update $lost/$trials, story content damaged $damaged/$trials"; fi
done
printf '  --- a damaged story from the last 8-way trial ---\n'; sed 's/^/      /' "$T/r.md"
summary
