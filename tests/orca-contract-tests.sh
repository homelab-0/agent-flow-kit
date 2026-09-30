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
if [[ "${ORCA_FAIL_MODE:-}" == timeout ]]; then exit 124; fi
if [[ "${ORCA_FAIL_MODE:-}" == cli-error ]]; then
  printf '{"ok":false,"error":{"code":"fixture_failure"}}\n'
  exit 1
fi
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
if [[ "${ORCA_FAIL_MODE:-}" == timeout ]]; then exit 124; fi
if [[ "${ORCA_FAIL_MODE:-}" == cli-error ]]; then
  printf '{"ok":false,"error":{"code":"fixture_failure"}}\n'
  exit 1
fi
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

# Contract shape failures are INVALID_CONTRACT and are rejected before any
# registry call, including missing per-command fields and empty collections.
cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract.json"
jq '(.commands[0]) |= del(.flags)' "$TMP/contract.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/contract.json"
afk_orca_contract_check; eq 'command missing flags is invalid contract' "$?" 5
eq 'malformed command class' "$AFK_ORCA_VERIFY_CLASS" INVALID_CONTRACT
cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract.json"
jq '.commands=[]' "$TMP/contract.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/contract.json"
afk_orca_contract_check; eq 'empty commands is invalid contract' "$?" 5
eq 'empty commands class' "$AFK_ORCA_VERIFY_CLASS" INVALID_CONTRACT
cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract.json"
jq '.known_defects=[]' "$TMP/contract.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/contract.json"
afk_orca_contract_check; eq 'empty defects is invalid contract' "$?" 5
eq 'empty defects class' "$AFK_ORCA_VERIFY_CLASS" INVALID_CONTRACT
cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract.json"
jq '(.known_defects[0].id)=""' "$TMP/contract.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/contract.json"
afk_orca_contract_check; eq 'empty defect id is invalid contract' "$?" 5
eq 'empty defect id class' "$AFK_ORCA_VERIFY_CLASS" INVALID_CONTRACT
cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract.json"
jq '(.known_defects[0].id)="defect.capabilites-command"' "$TMP/contract.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/contract.json"
afk_orca_contract_check; eq 'typo defect id is invalid contract' "$?" 5
eq 'typo defect id class' "$AFK_ORCA_VERIFY_CLASS" INVALID_CONTRACT
cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract.json"
jq '.known_defects[1].id=.known_defects[0].id' "$TMP/contract.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/contract.json"
afk_orca_contract_check; eq 'duplicate defect id is invalid contract' "$?" 5
eq 'duplicate defect id class' "$AFK_ORCA_VERIFY_CLASS" INVALID_CONTRACT
cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract.json"

# A bounded CLI timeout and an Orca error envelope are both unavailable, not
# resolver failures; preserve the underlying reason in JSON.
ORCA_FAIL_MODE=timeout afk_orca_contract_check; eq 'timeout exit is unavailable' "$?" 4
eq 'timeout class' "$AFK_ORCA_VERIFY_CLASS" ORCA_CLI_UNAVAILABLE
contains "$AFK_ORCA_VERIFY_JSON" '"reason_code":"ORCA_TIMEOUT"' 'timeout reason not retained'
if [[ "$AFK_ORCA_VERIFY_JSON" == *'"class":"ORCA_CLI_NOT_RESOLVED"'* ]]; then
  no 'timeout was mislabeled unresolved'
else
  ok
fi
ORCA_FAIL_MODE=cli-error afk_orca_contract_check; eq 'CLI error exit is unavailable' "$?" 4
eq 'CLI error class' "$AFK_ORCA_VERIFY_CLASS" ORCA_CLI_UNAVAILABLE
contains "$AFK_ORCA_VERIFY_JSON" '"reason_code":"ORCA_ERROR:fixture_failure"' 'CLI failure reason not retained'

# Static coverage check for direct literal call sites, including the legacy
# dispatch wrappers until ORCA-4. The fixture proves a new flag is rejected.
coverage_check() {
  python3 - "$1" "${2:-$ROOT/lifecycle/orca-contract.json}" <<'PY'
import json, pathlib, re, shlex, sys

target = pathlib.Path(sys.argv[1])
contract = json.loads(pathlib.Path(sys.argv[2]).read_text())
files = [target] if target.is_file() else [
    p for p in target.rglob('*') if p.is_file() and p.suffix in ('.sh', '')
]
known = {entry['command']: set(entry['flags']) for entry in contract['commands']}
roots = {'skills', 'terminal', 'worktree', 'repo', 'orchestration'}
direct = {'afk_orca_run', 'orca_json', 'bounded_orca'}
errors = []

def logical_lines(text):
    pending, start = '', 1
    for number, physical in enumerate(text.splitlines(), 1):
        if not pending:
            start = number
        stripped = physical.rstrip()
        if re.search(r'(?<!\\)\\$', stripped):
            pending += stripped[:-1] + ' '
            continue
        yield start, pending + physical.lstrip()
        pending = ''
    if pending:
        yield start, pending

def words(text):
    try:
        return shlex.split(text, comments=True)
    except ValueError:
        return []

def command_flags(args):
    args = [x for x in args if x not in (';', '&&', '||', '|', ')', '}')]
    if not args or args[0].startswith('$'):
        return None, set()
    if args[0] in roots:
        if len(args) < 2 or args[1].startswith(('-', '$')):
            return ' '.join(args[:2]), set()
        command, rest = ' '.join(args[:2]), args[2:]
    else:
        command, rest = args[0], args[1:]
    flags = {m.group(1) for x in rest if (m := re.match(r'^--([a-z][a-z0-9-]*)', x))}
    return command, flags

def caller_function(lines, line_number):
    current = None
    for number, line in enumerate(lines, 1):
        header = re.match(r'^\s*([A-Za-z_]\w*)\s*\(\)\s*\{', line)
        if header:
            current = header.group(1)
        if number == line_number:
            return current
        if current and re.match(r'^\s*}\s*$', line):
            current = None
    return None

forwarders = set()
for path in files:
    text = path.read_text(errors='ignore')
    for match in re.finditer(r'(?ms)^([A-Za-z_]\w*)\s*\(\)\s*\{(.*?)(?=^\s*\})', text):
        if 'afk_orca_run' in match.group(2) and re.search(r'"\$@"|\$\{@\}', match.group(2)):
            forwarders.add(match.group(1))
wrappers = direct | forwarders

defect_calls = []
for defect in contract.get('known_defects', []):
    fn = re.search(r'([A-Za-z_]\w*)\s*\(', defect.get('where', ''))
    command, flags = command_flags(words(defect.get('call', '')))
    if fn and command:
        defect_calls.append((defect.get('id'), fn.group(1), command, flags))

for path in files:
    physical = path.read_text(errors='ignore').splitlines()
    statements = list(logical_lines('\n'.join(physical)))
    arrays = {}
    for _, statement in statements:
        match = re.search(r'\b([A-Za-z_]\w*)\s*(\+?=)\s*\((.*)\)', statement)
        if not match:
            continue
        name, op, value = match.groups()
        parts = words(value)
        if any('$' in x and not re.fullmatch(r'\$[A-Za-z_]\w*', x) for x in parts):
            arrays.pop(name, None)
            continue
        parts = [x for x in parts if x != ')']
        if op == '+=':
            if name in arrays:
                arrays[name].extend(parts)
            else:
                arrays.pop(name, None)
        else:
            arrays[name] = parts
    for line_number, statement in statements:
        if re.match(r'^\s*[A-Za-z_]\w*\s*\(\)\s*\{', statement):
            continue
        uncommented = statement.split('#', 1)[0]
        if re.match(r'^\s*(?:declare\s+-F|local\s+-F)\b', uncommented):
            continue
        pattern = r'(?<![A-Za-z0-9_])(' + '|'.join(map(re.escape, wrappers)) + r')(?![A-Za-z0-9_])'
        for match in re.finditer(pattern, uncommented):
            name = match.group(1)
            prefix = uncommented[:match.start()]
            if name == 'afk_orca_run' and caller_function(physical, line_number) in forwarders:
                continue
            if re.search(r'\bfunction\s*$', prefix) or re.search(r'\b[A-Za-z_]\w*\s*\(\s*$', prefix):
                continue
            tail = uncommented[match.end():]
            tail = tail.split('|', 1)[0]
            tail = re.sub(r'\)\s*"?\s*(?:\|\|.*)?$', '', tail)
            argv = words(tail)
            if name == 'afk_orca_run':
                try:
                    divider = argv.index('--')
                except ValueError:
                    if caller_function(physical, line_number) in forwarders:
                        continue
                    errors.append(f'{path}:{line_number}: unauditable afk_orca_run argv')
                    continue
                argv = argv[divider + 1:]
            if name in forwarders:
                if not argv:
                    errors.append(f'{path}:{line_number}: unauditable {name} argv')
                    continue
                argv = argv[1:]
            if argv:
                array = re.fullmatch(r'\$\{([A-Za-z_]\w*)\[@\]\}', argv[0])
                if array:
                    if array.group(1) not in arrays:
                        errors.append(f'{path}:{line_number}: unauditable argv array {array.group(1)}')
                        continue
                    argv = arrays[array.group(1)] + argv[1:]
            command, flags = command_flags(argv)
            if not command:
                errors.append(f'{path}:{line_number}: unauditable Orca argv for {name}')
                continue
            owner = caller_function(physical, line_number)
            defect = next((item for item in defect_calls
                           if owner == item[1] and command == item[2] and flags == item[3]
                           and (name not in forwarders or item[0] == 'defect.close-handle-durable')), None)
            if command not in known:
                if not defect:
                    errors.append(f'{path}:{line_number}: unknown Orca command {command} (caller {owner})')
                continue
            if defect:
                continue
            for flag in sorted(flags - known[command]):
                errors.append(f'{path}:{line_number}: {command} --{flag}')
if errors:
    print('\n'.join(errors))
    raise SystemExit(1)
PY
}
cat >"$TMP/site.sh" <<'SITE'
afk_orca_run coverage -- terminal list --json
SITE
coverage_check "$TMP/site.sh" && ok || no 'contracted fixture call site failed coverage'
cat >"$TMP/site.sh" <<'SITE'
afk_orca_run coverage -- terminal list --uncontracted-flag
SITE
if coverage_check "$TMP/site.sh" >/dev/null 2>&1; then no 'coverage accepted an uncontracted flag'; else ok; fi
cat >"$TMP/site.sh" <<'SITE'
afk_orca_run coverage -- uncontracted-command --json
SITE
if coverage_check "$TMP/site.sh" >/dev/null 2>&1; then no 'coverage accepted a new command'; else ok; fi
cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract-no-command-flag.json"
jq '(.commands[]|select(.command=="terminal create").flags) |= map(select(.!="command"))' \
  "$TMP/contract-no-command-flag.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/contract-no-command-flag.json"
cat >"$TMP/site.sh" <<'SITE'
orca_json terminal create --worktree "id:$selector" --title "$title" \
  --command "$command"
SITE
if coverage_check "$TMP/site.sh" "$TMP/contract-no-command-flag.json" >/dev/null 2>&1; then
  no 'coverage missed a flag on a continued dispatch-style call'
else
  ok
fi
cp "$ROOT/files/model-router/scripts/dispatch.sh" "$TMP/site.sh"
if coverage_check "$TMP/site.sh" "$TMP/contract-no-command-flag.json" >/dev/null 2>&1; then
  no 'coverage missed command-substitution terminal create --command call'
else
  ok
fi
cp "$ROOT/lifecycle/orca-contract.json" "$TMP/contract-no-send-flag.json"
jq '(.commands[]|select(.command=="orchestration send").flags) |= map(select(.!="payload"))' \
  "$TMP/contract-no-send-flag.json" >"$TMP/changed" && mv "$TMP/changed" "$TMP/contract-no-send-flag.json"
cp "$ROOT/files/model-router/scripts/dispatch.sh" "$TMP/site.sh"
if coverage_check "$TMP/site.sh" "$TMP/contract-no-send-flag.json" >/dev/null 2>&1; then
  no 'coverage missed array-built dispatch send --payload call'
else
  ok
fi
mkdir -p "$TMP/wrapper"
cat >"$TMP/wrapper/monitor.sh" <<'SITE'
afk_monitor_orca() {
  local purpose="$1"; shift
  afk_orca_run --bound 5 "$purpose" -- "$@"
}
afk_monitor_terminal_release() {
  afk_monitor_orca monitor-close terminal close --handle "$1" --durable --json
}
SITE
coverage_check "$TMP/wrapper" && ok || no 'known terminal-close defect exception did not match'
cat >>"$TMP/wrapper/monitor.sh" <<'SITE'
afk_monitor_orca monitor-close terminal close --handle "$1" --durable --uncontracted-flag
SITE
if coverage_check "$TMP/wrapper" >/dev/null 2>&1; then
  no 'forwarding wrapper accepted an unlisted flag'
else
  ok
fi
cat >>"$TMP/wrapper/monitor.sh" <<'SITE'
afk_monitor_other_close() {
  afk_monitor_orca monitor-close terminal close --handle "$1" --durable --json
}
SITE
if coverage_check "$TMP/wrapper" >/dev/null 2>&1; then
  no 'known close defect was allowed outside its named call site'
else
  ok
fi
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
