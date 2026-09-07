#!/usr/bin/env bash
# Deterministic gate for canary task T3.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "GATE FAIL (T3): $*"; exit 1; }

out="spike/out/dev-record.md"
[ -f "$out" ] || fail "$out does not exist"

head -n 1 "$out" | grep -Eq '^Persona: .+' || fail "first line of $out is not 'Persona: <name>'"

prev=0
for heading in '## Status' '## Implementation artifacts' '## Gates' \
               '## Findings and resolutions' '## Final diff size'; do
  line="$(grep -nxF "$heading" "$out" | head -n 1 | cut -d: -f1)"
  [ -n "$line" ] || fail "missing heading in $out: $heading"
  [ "$line" -gt "$prev" ] || fail "heading out of order in $out: $heading"
  body="$(sed -n "$((line + 1))p" "$out")"
  [ -n "${body//[[:space:]]/}" ] || fail "heading not followed by a non-empty line in $out: $heading"
  prev="$line"
done

echo "GATE PASS (T3): $out has the persona line and the five headings in order"
