#!/usr/bin/env bash
# Unit and integration checks for the static Orca contract.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf -- "$TMP"' EXIT
pass=0 fail=0 skip=0
ok() { pass=$((pass + 1)); }
no() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
eq() { [[ "$2" == "$3" ]] && ok || no "$1 expected=$3 got=$2"; }
contains() { grep -Fq -- "$2" <<<"$1" && ok || no "$3"; }

cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract.json"
cp "$ROOT/tests/fixtures/orca/agent-context-1.4.217.json" "$TMP/registry.json"
cat >"$TMP/orca" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then printf '1.4.217\n'; exit 0; fi
[[ "${1:-}" == agent-context && "${2:-}" == --json ]] || exit 64
cat "$ORCA_REGISTRY"
STUB
chmod +x "$TMP/orca"
export ORCA_CLI_COMMAND="$TMP/orca" ORCA_REGISTRY="$TMP/registry.json" AFK_ORCA_CONTRACT="$TMP/contract.json"
. "$ROOT/lib/afk-orca.sh"
. "$ROOT/lib/afk-orca-verify.sh"

afk_orca_contract_check; eq 'trimmed fixture passes' "$?" 0
contains "$AFK_ORCA_VERIFY_JSON" '"class":"OK"' 'JSON pass class missing'

# The shim logs invocations separately; every check makes one data call (the
# resolver's --version is a distinct, mandatory cached resolution step).
cat >"$TMP/orca" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == --version ]]; then printf '1.4.217\n'; exit 0; fi
printf '%s\n' "$*" >>"$ORCA_CALL_LOG"
[[ "${1:-}" == agent-context && "${2:-}" == --json ]] || exit 64
cat "$ORCA_REGISTRY"
STUB
chmod +x "$TMP/orca"; export ORCA_CALL_LOG="$TMP/calls"; : >"$TMP/calls"
afk_orca_contract_check; eq 'one bounded call succeeds' "$?" 0
eq 'one registry call' "$(wc -l <"$TMP/calls" | tr -d ' ')" 1
eq 'registry call arguments' "$(cat "$TMP/calls")" 'agent-context --json'

# A removed contract flag is named in the failure result.
jq '(.commands[]|select(.command=="terminal list").flags) |= map(select(.!="limit"))' "$TMP/registry.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/registry.json"
afk_orca_contract_check; eq 'removed flag has missing-item exit' "$?" 2
contains "$AFK_ORCA_VERIFY_JSON" '"flag":"limit","status":"missing"' 'removed flag item not named'

# A removed command is likewise reported by id.
cp "$ROOT/tests/fixtures/orca/agent-context-1.4.217.json" "$TMP/registry.json"
jq '.commands |= map(select(.command!="terminal wait"))' "$TMP/registry.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/registry.json"
afk_orca_contract_check; eq 'removed command has missing-item exit' "$?" 2
contains "$AFK_ORCA_VERIFY_JSON" '"id":"cmd.terminal-wait"' 'removed command id not named'
contains "$AFK_ORCA_VERIFY_JSON" '"command":"terminal wait"' 'removed command is not named'
contains "$AFK_ORCA_VERIFY_JSON" '"status":"missing"' 'removed command status missing'

# Reintroducing an unsupported command/flag is a distinct failure class.
jq '.commands += [{"command":"capabilities","flags":["json"]}]' "$TMP/registry.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/registry.json"
afk_orca_contract_check; eq 'reappeared defect has distinct exit' "$?" 3
contains "$AFK_ORCA_VERIFY_JSON" '"id":"defect.capabilities-command"' 'reappeared defect is not named'

# Static coverage check for direct literal call sites, including the legacy
# dispatch wrappers until ORCA-4. The fixture proves a new flag is rejected.
coverage_check() {
  python3 - "$1" "$ROOT/lifecycle/orca-contract.json" <<'PY'
import json, pathlib, re, shlex, sys
target = pathlib.Path(sys.argv[1])
files = [target] if target.is_file() else [p for p in target.rglob('*') if p.is_file() and p.suffix in ('.sh', '')]
contract = json.loads(pathlib.Path(sys.argv[2]).read_text())
known = {entry['command']: set(entry['flags']) for entry in contract['commands']}
errors = []
for path in files:
 for line in path.read_text(errors='ignore').splitlines():
  if not any(name in line for name in ('afk_orca_run', 'orca_json', 'bounded_orca')): continue
  match = re.search(r'\s--\s+(.*)$', line)
  after = match.group(1) if match else line
  try: words = shlex.split(after, comments=True)
  except ValueError: continue
  for command in sorted(known, key=lambda x: -len(x.split())):
   parts = command.split()
   for i in range(max(0, len(words)-len(parts)+1)):
    if words[i:i+len(parts)] == parts:
     for word in words[i+len(parts):]:
      if word.startswith('--') and re.fullmatch(r'--[a-z][a-z0-9-]*', word):
       flag = word[2:]
       if flag not in known[command]: errors.append(f'{path}: {command} --{flag}')
     break
if errors:
    print('\n'.join(errors)); raise SystemExit(1)
PY
}
cat >"$TMP/site.sh" <<'SITE'
afk_orca_run coverage -- terminal list --json
SITE
coverage_check "$TMP/site.sh" && ok || no 'contracted fixture call site failed coverage'
cat >>"$TMP/site.sh" <<'SITE'
afk_orca_run coverage -- terminal list --uncontracted-flag
SITE
if coverage_check "$TMP/site.sh" >/dev/null 2>&1; then no 'coverage accepted an uncontracted flag'; else ok; fi
mkdir -p "$TMP/code/lib" "$TMP/code/adapters" "$TMP/code/files/model-router/scripts"
cp "$ROOT"/lib/*.sh "$TMP/code/lib/"
cp "$ROOT"/adapters/*.sh "$TMP/code/adapters/" 2>/dev/null || true
cp "$ROOT/files/model-router/scripts/dispatch.sh" "$TMP/code/files/model-router/scripts/" 2>/dev/null || true
coverage_check "$TMP/code" && ok || no 'repository Orca literal coverage failed'

# The public verb preserves the result JSON and distinct exit codes.
CLI="$ROOT/bin/agent-flow-kit"
ORCA_REGISTRY="$ROOT/tests/fixtures/orca/agent-context-1.4.217.json" "$CLI" orca-verify --contract --json >"$TMP/verb.json"
eq 'verb pass exit' "$?" 0
contains "$(cat "$TMP/verb.json")" '"items"' 'verb JSON lacks item statuses'

# The live check is informational when the configured Orca CLI is unavailable.
if [[ -x "$HOME/.local/bin/orca-ide" ]]; then
  ORCA_CLI_COMMAND="$HOME/.local/bin/orca-ide" AFK_ORCA_CONTRACT="$ROOT/lifecycle/orca-contract.json" \
    bash -c '. "$1/lib/afk-orca.sh"; . "$1/lib/afk-orca-verify.sh"; afk_orca_contract_check' _ "$ROOT" >/dev/null 2>&1
  [[ $? == 0 ]] && { printf 'real CLI: passed\n'; ok; } || no 'real CLI contract check failed'
else
  printf 'real CLI: skipped\n'; skip=$((skip + 1))
fi

printf 'Orca contract: %d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
(( fail == 0 ))
