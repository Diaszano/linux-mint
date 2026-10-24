#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
    mkdir -p "$HOME"
    ROLLBACK="$ROOT/bin/dev-rollback"
    MANIFEST="$ROOT/lib/manifest.py"
}

manifest() { python3 "$MANIFEST" "$@"; }

prepare_file() {
    printf 'original\n' >"$BATS_TEST_TMPDIR/target"
    printf 'installed\n' >"$BATS_TEST_TMPDIR/source"
    chmod 640 "$BATS_TEST_TMPDIR/target"
    RUN_ID="$(manifest init)"
    manifest install "$RUN_ID" baseline "$BATS_TEST_TMPDIR/source" "$BATS_TEST_TMPDIR/target"
    JOURNAL="$XDG_STATE_HOME/vaio-fe16-dev-setup/runs/$RUN_ID/manifest.jsonl"
}

append_state() {
    local event
    event="$(python3 -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1])))' "$1")"
    manifest append "$RUN_ID" "$event"
}

fake_systemctl() {
    mkdir "$BATS_TEST_TMPDIR/bin"
    export SERVICE_STATE="$BATS_TEST_TMPDIR/service.json" SERVICE_LOG="$BATS_TEST_TMPDIR/service.log"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    cat >"$BATS_TEST_TMPDIR/bin/systemctl" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, sys
args = sys.argv[1:]
state = pathlib.Path(os.environ['SERVICE_STATE'])
enabled, active = json.loads(state.read_text())
with open(os.environ['SERVICE_LOG'], 'a') as log:
    log.write(' '.join(args) + '\n')
if args[1] == 'show':
    print('UnitFileState=' + enabled)
    print('ActiveState=' + ('active' if active else 'inactive'))
else:
    assert not os.environ.get('FORBID_SERVICE_WRITES')
    action = args[1]
    if action in ('enable', 'disable', 'mask', 'unmask'):
        enabled = {'enable': 'enabled', 'disable': 'disabled', 'mask': 'masked', 'unmask': 'disabled'}[action]
    elif action in ('start', 'stop'):
        active = action == 'start'
    else:
        sys.exit(1)
    state.write_text(json.dumps([enabled, active]))
PY
    chmod +x "$BATS_TEST_TMPDIR/bin/systemctl"
    printf '["enabled", true]' >"$SERVICE_STATE"
    RUN_ID="$(manifest init)"
    local event='{"event":"service","status":"intent","module":"baseline","unit":"example.service","scope":"user","before_enabled":"disabled","before_active":false,"applied_enabled":"enabled","applied_active":true}'
    append_state "$event"
    append_state "${event/\"intent\"/\"applied\"}"
}

@test "sourcing rollback and listing before first run create no state" {
    run bash -c 'source "$1/lib/rollback.sh"' _ "$ROOT"
    [ "$status" -eq 0 ]
    run "$ROLLBACK" --list
    [ "$status" -eq 0 ]
    [ "$output" = '[]' ]
    [ ! -e "$XDG_STATE_HOME" ]
}

@test "list and dry-run leave journal backups and targets unchanged" {
    prepare_file
    before="$(find "$XDG_STATE_HOME" "$BATS_TEST_TMPDIR/target" -type f -exec sha256sum {} +)"
    run "$ROLLBACK" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"$RUN_ID"* ]]
    run "$ROLLBACK" "$RUN_ID" --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *'Restaurar'* ]]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = installed ]
    [ "$before" = "$(find "$XDG_STATE_HOME" "$BATS_TEST_TMPDIR/target" -type f -exec sha256sum {} +)" ]
    [ "$(wc -l <"$JOURNAL")" -eq 4 ]
}

@test "apply requires confirmation and restores bytes mode and owner" {
    prepare_file
    owner="$(stat -c '%u:%g' "$BATS_TEST_TMPDIR/target")"
    chmod 600 "$BATS_TEST_TMPDIR/target"
    run bash -c '"$1" "$2" < /dev/null' _ "$ROLLBACK" "$RUN_ID"
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = installed ]
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = original ]
    [ "$(stat -c '%a' "$BATS_TEST_TMPDIR/target")" = 640 ]
    [ "$(stat -c '%u:%g' "$BATS_TEST_TMPDIR/target")" = "$owner" ]
    manifest verify "$RUN_ID"
    [ "$(wc -l <"$JOURNAL")" -eq 6 ]
}

@test "later edits are conflicts in preview and apply and remain unchanged" {
    prepare_file
    printf 'user-edited\n' >"$BATS_TEST_TMPDIR/target"
    for flag in --dry-run --yes; do
        run "$ROLLBACK" "$RUN_ID" "$flag"
        [ "$status" -ne 0 ]
        [[ "$output" == *'Conflito'* ]]
        [ "$(cat "$BATS_TEST_TMPDIR/target")" = user-edited ]
        [ "$(wc -l <"$JOURNAL")" -eq 4 ]
    done
}

@test "new owned files are removed only if unchanged" {
    printf created >"$BATS_TEST_TMPDIR/source"
    RUN_ID="$(manifest init)"
    manifest install "$RUN_ID" baseline "$BATS_TEST_TMPDIR/source" "$BATS_TEST_TMPDIR/new"
    manifest install "$RUN_ID" baseline "$BATS_TEST_TMPDIR/source" "$BATS_TEST_TMPDIR/edited"
    printf edited >"$BATS_TEST_TMPDIR/edited"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/new" ]
    [ "$(cat "$BATS_TEST_TMPDIR/edited")" = edited ]
}

@test "repeated rollback is harmless and does not append duplicate events" {
    prepare_file
    "$ROLLBACK" "$RUN_ID" --yes
    before="$(sha256sum "$JOURNAL" "$BATS_TEST_TMPDIR/target")"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -eq 0 ]
    [ "$before" = "$(sha256sum "$JOURNAL" "$BATS_TEST_TMPDIR/target")" ]
    printf later >"$BATS_TEST_TMPDIR/target"
    "$ROLLBACK" "$RUN_ID" --yes
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = later ]
}

@test "multiple writes restore the initial snapshot once in reverse operation order" {
    prepare_file
    printf second >"$BATS_TEST_TMPDIR/source"
    manifest install "$RUN_ID" baseline "$BATS_TEST_TMPDIR/source" "$BATS_TEST_TMPDIR/second"
    printf final >"$BATS_TEST_TMPDIR/source"
    manifest install "$RUN_ID" baseline "$BATS_TEST_TMPDIR/source" "$BATS_TEST_TMPDIR/target"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = original ]
    [ ! -e "$BATS_TEST_TMPDIR/second" ]
    python3 - "$JOURNAL" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1])]
operations = [e['operation'] for e in events if e['event'] == 'rollback' and e['status'] == 'applied']
assert operations == [8, 6], operations
PY
}

@test "intent-only interruption prints exact manual recovery backup and target" {
    prepare_file
    python3 - "$JOURNAL" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1]); p.write_text(''.join(p.read_text().splitlines(True)[:-1]))
PY
    backup="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[1])["backup"])' "$JOURNAL")"
    before="$(sha256sum "$JOURNAL" "$BATS_TEST_TMPDIR/target")"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *'manual'* ]]
    [[ "$output" == *"$backup"* ]]
    [[ "$output" == *"$BATS_TEST_TMPDIR/target"* ]]
    [[ "$output" == *'cp --preserve=mode,ownership,timestamps --'* ]]
    [ "$before" = "$(sha256sum "$JOURNAL" "$BATS_TEST_TMPDIR/target")" ]
}

@test "unknown and malformed run ids fail without creating state" {
    for id in ../../escape 00000000000000000000-0000000000000000; do
        run "$ROLLBACK" "$id" --yes
        [ "$status" -ne 0 ]
        [ ! -e "$XDG_STATE_HOME" ]
    done
}

@test "malformed journal fails before touching any target" {
    prepare_file
    printf '{"event":"unknown"}\n' >>"$JOURNAL"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = installed ]
}

@test "valid schema but unpaired applied entry fails before writes" {
    prepare_file
    python3 - "$JOURNAL" <<'PY'
import json, sys
with open(sys.argv[1], 'a') as f:
    f.write(json.dumps({'event':'applied','module':'baseline','path':'/unowned','applied_sha256':'0'*64}) + '\n')
PY
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = installed ]
}

@test "symlink target and tampered backup fail without overwriting other files" {
    prepare_file
    printf outsider >"$BATS_TEST_TMPDIR/outside"
    rm "$BATS_TEST_TMPDIR/target"
    ln -s "$BATS_TEST_TMPDIR/outside" "$BATS_TEST_TMPDIR/target"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [ -L "$BATS_TEST_TMPDIR/target" ]
    [ "$(cat "$BATS_TEST_TMPDIR/outside")" = outsider ]
    rm "$BATS_TEST_TMPDIR/target"
    printf installed >"$BATS_TEST_TMPDIR/target"
    backup="$(python3 -c 'import json,sys; print(json.loads(open(sys.argv[1]).readlines()[1])["backup"])' "$JOURNAL")"
    printf bad >"$backup"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = installed ]
}

@test "package events only propose review and never remove packages" {
    mkdir "$BATS_TEST_TMPDIR/bin"
    export PACKAGE_MUTATION="$BATS_TEST_TMPDIR/package-mutation"
    export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    for command in apt apt-get dpkg; do
        printf '#!/usr/bin/env bash\n: > "$PACKAGE_MUTATION"\nexit 77\n' >"$BATS_TEST_TMPDIR/bin/$command"
        chmod +x "$BATS_TEST_TMPDIR/bin/$command"
    done
    RUN_ID="$(manifest init)"
    append_state '{"event":"package","module":"baseline","package":"example:amd64","before_installed":false,"applied_installed":true}'
    append_state '{"event":"package","module":"baseline","package":"preexisting","before_installed":true,"applied_installed":true}'
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -eq 0 ]
    [[ "$output" == *'example:amd64'* ]]
    [[ "$output" == *'manual'* ]]
    [[ "$output" != *'preexisting'* ]]
    [ ! -e "$PACKAGE_MUTATION" ]
    manifest verify "$RUN_ID"
}

@test "service preview only probes and apply restores enabled and active before-state" {
    fake_systemctl
    export FORBID_SERVICE_WRITES=1
    run "$ROLLBACK" "$RUN_ID" --dry-run
    [ "$status" -eq 0 ]
    [ "$(cat "$SERVICE_STATE")" = '["enabled", true]' ]
    unset FORBID_SERVICE_WRITES
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -eq 0 ]
    [ "$(cat "$SERVICE_STATE")" = '["disabled", false]' ]
    [[ "$(cat "$SERVICE_LOG")" == *'--user stop example.service'* ]]
    [[ "$(cat "$SERVICE_LOG")" == *'--user disable example.service'* ]]
    before="$(cat "$SERVICE_LOG")"
    "$ROLLBACK" "$RUN_ID" --yes
    [ "$before" = "$(cat "$SERVICE_LOG")" ]
    manifest verify "$RUN_ID"
}

@test "service later state changes are skipped safely" {
    fake_systemctl
    printf '["enabled", false]' >"$SERVICE_STATE"
    export FORBID_SERVICE_WRITES=1
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *'Conflito'* ]]
    [ "$(cat "$SERVICE_STATE")" = '["enabled", false]' ]
}

@test "new event schemas reject unsafe units state enums and rollback references" {
    RUN_ID="$(manifest init)"
    for event in \
        '{"event":"service","status":"intent","module":"baseline","unit":"--bad.service","scope":"user","before_enabled":"disabled","before_active":false,"applied_enabled":"enabled","applied_active":true}' \
        '{"event":"service","status":"intent","module":"baseline","unit":"example.service","scope":"user","before_enabled":"unknown","before_active":false,"applied_enabled":"enabled","applied_active":true}' \
        '{"event":"package","module":"baseline","package":"--bad","before_installed":false,"applied_installed":true}' \
        '{"event":"rollback","operation":999,"status":"applied"}'; do
        run append_state "$event"
        [ "$status" -ne 0 ]
    done
    manifest verify "$RUN_ID"
}

@test "interrupted rollback after restore resumes without overwriting later edits" {
    prepare_file
    run python3 - "$MANIFEST" "$RUN_ID" <<'PY'
import importlib.util, sys
from unittest.mock import patch
spec = importlib.util.spec_from_file_location('manifest', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
append = m.append_event
def interrupt(fd, event):
    if event['event'] == 'rollback' and event['status'] == 'applied':
        raise OSError('simulated loss before completion append')
    return append(fd, event)
with patch.object(m, 'append_event', side_effect=interrupt):
    if not m.rollback_run(sys.argv[2], apply=True):
        sys.exit(3)
PY
    [ "$status" -eq 3 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = original ]
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -eq 0 ]
    manifest verify "$RUN_ID"
    [ "$(wc -l <"$JOURNAL")" -eq 6 ]
}

@test "service intent without applied confirmation requires exact manual recovery" {
    fake_systemctl
    RUN_ID="$(manifest init)"
    append_state '{"event":"service","status":"intent","module":"baseline","unit":"pending.service","scope":"system","before_enabled":"disabled","before_active":false,"applied_enabled":"enabled","applied_active":true}'
    export FORBID_SERVICE_WRITES=1
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *'manual'* ]]
    [[ "$output" == *'systemctl --system stop pending.service'* ]]
    [[ "$output" == *'systemctl --system disable pending.service'* ]]
}

@test "later edit after interrupted rollback is preserved" {
    prepare_file
    python3 - "$JOURNAL" <<'PY'
import json, sys
with open(sys.argv[1], 'a') as f:
    f.write(json.dumps({'event':'rollback','operation':3,'status':'intent'}) + '\n')
PY
    printf later >"$BATS_TEST_TMPDIR/target"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = later ]
}

@test "new empty owned file deletion and repeated rollback are harmless" {
    : >"$BATS_TEST_TMPDIR/source"
    RUN_ID="$(manifest init)"
    manifest install "$RUN_ID" baseline "$BATS_TEST_TMPDIR/source" "$BATS_TEST_TMPDIR/empty"
    "$ROLLBACK" "$RUN_ID" --yes
    [ ! -e "$BATS_TEST_TMPDIR/empty" ]
    "$ROLLBACK" "$RUN_ID" --yes
    [ ! -e "$BATS_TEST_TMPDIR/empty" ]
}

@test "service rollback can restore masked state and restart a previously active system service" {
    fake_systemctl
    RUN_ID="$(manifest init)"
    event='{"event":"service","status":"intent","module":"baseline","unit":"example.service","scope":"system","before_enabled":"masked","before_active":false,"applied_enabled":"enabled","applied_active":true}'
    append_state "$event"
    append_state "${event/\"intent\"/\"applied\"}"
    "$ROLLBACK" "$RUN_ID" --yes
    [ "$(cat "$SERVICE_STATE")" = '["masked", false]' ]
    [[ "$(cat "$SERVICE_LOG")" == *'--system mask example.service'* ]]
    RUN_ID="$(manifest init)"
    event='{"event":"service","status":"intent","module":"baseline","unit":"example.service","scope":"system","before_enabled":"enabled","before_active":true,"applied_enabled":"masked","applied_active":false}'
    append_state "$event"
    append_state "${event/\"intent\"/\"applied\"}"
    "$ROLLBACK" "$RUN_ID" --yes
    [ "$(cat "$SERVICE_STATE")" = '["enabled", true]' ]
    [[ "$(cat "$SERVICE_LOG")" == *'--system unmask example.service'* ]]
    [[ "$(cat "$SERVICE_LOG")" == *'--system start example.service'* ]]
}

@test "unknown service state refuses mutation and prints recovery commands" {
    fake_systemctl
    printf '["enabled-runtime", true]' >"$SERVICE_STATE"
    export FORBID_SERVICE_WRITES=1
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [[ "$output" == *'manual'* ]]
    [[ "$output" == *'systemctl --user disable example.service'* ]]
    [ "$(cat "$SERVICE_STATE")" = '["enabled-runtime", true]' ]
}

@test "missing journal newline and out-of-run rollback references fail before writes" {
    prepare_file
    cp "$JOURNAL" "$BATS_TEST_TMPDIR/good-journal"
    truncate -s -1 "$JOURNAL"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = installed ]
    cp "$BATS_TEST_TMPDIR/good-journal" "$JOURNAL"
    printf '{"event":"rollback","operation":99999,"status":"intent"}\n' >>"$JOURNAL"
    run "$ROLLBACK" "$RUN_ID" --yes
    [ "$status" -ne 0 ]
    [ "$(cat "$BATS_TEST_TMPDIR/target")" = installed ]
}

@test "listing keeps healthy runs visible alongside invalidly named entries" {
    prepare_file
    mkdir "$(dirname "$(dirname "$JOURNAL")")/invalid-entry"
    run "$ROLLBACK" --list
    [ "$status" -eq 0 ]
    [[ "$output" == *"$RUN_ID"* ]]
    [ "$(wc -l <"$JOURNAL")" -eq 4 ]
}
