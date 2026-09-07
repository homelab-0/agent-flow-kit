#!/usr/bin/env bash
# Deterministic gate for canary task T2.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "GATE FAIL (T2): $*"; exit 1; }

out="spike/out/wordfreq.sh"
[ -f "$out" ] || fail "$out does not exist"

actual="$(printf '%s\n' 'the cat and the dog and the bird. The DOG!' | bash "$out" 2>&1)" \
  || fail "$out exited non-zero: $actual"
expected='the 4
and 2
dog 2'
[ "$actual" = "$expected" ] || fail "$out output differs: got $(printf '%s' "$actual" | tr '\n' '/')"

echo "GATE PASS (T2): $out reports the expected top-three word frequencies"
