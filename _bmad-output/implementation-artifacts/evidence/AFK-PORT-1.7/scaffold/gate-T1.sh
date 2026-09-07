#!/usr/bin/env bash
# Deterministic gate for canary task T1.
set -uo pipefail
cd "$(dirname "$0")/../.."
fail() { echo "GATE FAIL (T1): $*"; exit 1; }

out="spike/out/t1.txt"
[ -f "$out" ] || fail "$out does not exist"

expected_sha="$(sha256sum <<<'persona payload viability spike
AFK-PORT-1.7 T1' | cut -d' ' -f1)"
actual_sha="$(sha256sum "$out" | cut -d' ' -f1)"
[ "$actual_sha" = "$expected_sha" ] || fail "$out bytes differ: $actual_sha != $expected_sha"

echo "GATE PASS (T1): $out matches the expected bytes"
