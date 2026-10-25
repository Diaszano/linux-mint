#!/usr/bin/env bats
setup() {
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    chmod 700 "$BATS_TEST_TMPDIR" "$(dirname "$BATS_TEST_TMPDIR")"
    export HOME="$BATS_TEST_TMPDIR/home"
    export XDG_CONFIG_HOME="$HOME/.config"
    export XDG_RUNTIME_DIR="$BATS_TEST_TMPDIR/runtime"
    export FIXTURE="$BATS_TEST_TMPDIR" PATH="$BATS_TEST_TMPDIR/bin:$PATH"
    mkdir -p "$HOME" "$XDG_RUNTIME_DIR" "$FIXTURE/bin"
    chmod 700 "$XDG_RUNTIME_DIR"
    cat >"$FIXTURE/bin/systemd-run" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$FIXTURE/request"
while (($#)); do
    case $1 in
        --unit=*) printf '%s' "${1#*=}" > "$FIXTURE/unit" ;;
        */dev-gate) break ;;
    esac
    shift
done
[[ ${FAILURE:-} != manager ]] || exit 1
[[ ${FAILURE:-} != timeout ]] || { sleep 20; exit 1; }
exec "$@"
SH
    cat >"$FIXTURE/bin/systemctl" <<'SH'
#!/usr/bin/env bash
[[ ${FAILURE:-} != manager ]] || exit 1
case " $* " in
    *' kill '*)
        printf 'kill\n' >> "$FIXTURE/cleanup"
        exit 0 ;;
    *' show '*)
        [[ ${FAILURE:-} != disappear || ! -f "$FIXTURE/shown" ]] || exit 1
        touch "$FIXTURE/shown"
        unit=$(cat "$FIXTURE/unit")
        if [[ ${FAILURE:-} == inactive ]]; then echo ActiveState=inactive; else echo ActiveState=active; fi
        printf 'ControlGroup=/fake/%s\n' "$unit"
        while read -r item; do
            case $item in
                CPUQuota=*) cpu=${item#*=}; cpu=${cpu%%%}; printf 'CPUQuotaPerSecUSec=%sms\n' "$((cpu * 10))" ;;
                MemoryHigh=*|MemoryMax=*|MemorySwapMax=*|TasksMax=*)
                    if [[ ${FAILURE:-} == "property_${item%%=*}" ]]; then printf '%s=1\n' "${item%%=*}"; else printf '%s\n' "$item"; fi ;;
            esac
        done < "$FIXTURE/request" ;;
    *) exit 99 ;;
esac
SH
    cat >"$FIXTURE/bin/cat" <<'SH'
#!/usr/bin/env bash
case ${1:-} in
    /proc/meminfo) printf 'MemTotal: %s kB\n' "${RAM_KB:-23068672}" ;;
    /proc/[0-9]*/cgroup)
        [[ ${FAILURE:-} != wrong_pid ]] || { printf '0::/wrong\n'; exit; }
        printf '0::/fake/%s\n' "$(/usr/bin/cat "$FIXTURE/unit")" ;;
    /sys/fs/cgroup/fake/dev-*.scope/*)
        name=${1##*/}
        [[ ${FAILURE:-} != "missing_$name" ]] || exit 1
        [[ ${FAILURE:-} != "malformed_$name" ]] || { echo invalid; exit; }
        [[ ${FAILURE:-} != "unbounded_$name" ]] || { echo max; exit; }
        [[ ${FAILURE:-} != "loose_$name" ]] || { if [[ $name == cpu.max ]]; then echo '900000 100000'; else echo 999999999999; fi; exit; }
        case $name in
            cpu.max)
                value=$(/usr/bin/sed -n 's/^CPUQuota=\([0-9]*\)%$/\1/p' "$FIXTURE/request")
                printf '%s 100000\n' "$((value * 1000))" ;;
            memory.high) /usr/bin/sed -n 's/^MemoryHigh=//p' "$FIXTURE/request" ;;
            memory.max) /usr/bin/sed -n 's/^MemoryMax=//p' "$FIXTURE/request" ;;
            memory.swap.max) /usr/bin/sed -n 's/^MemorySwapMax=//p' "$FIXTURE/request" ;;
            pids.max) /usr/bin/sed -n 's/^TasksMax=//p' "$FIXTURE/request" ;;
            *) exit 1 ;;
        esac ;;
    /sys/fs/cgroup/*/cpu.max|/sys/fs/cgroup/cpu.max) echo 'max 100000' ;;
    /sys/fs/cgroup/*/memory.*|/sys/fs/cgroup/memory.*|/sys/fs/cgroup/*/pids.max|/sys/fs/cgroup/pids.max) echo max ;;
    *) exec /usr/bin/cat "$@" ;;
esac
SH
    printf '#!/bin/sh\necho "${THREADS:-16}"\n' >"$FIXTURE/bin/nproc"
    chmod +x "$FIXTURE/bin/"*
}

@test "balanced data table contains the three approved ceilings" {
    run cat "$ROOT/config/profiles.conf"
    [ "$status" = 0 ]
    [[ "$output" == *$'build\t800\t7\t9\t2\t1024'* ]]
    [[ "$output" == *$'emulator\t400\t5\t6\t1\t512'* ]]
    [[ "$output" == *$'heavy\t600\t6\t8\t2\t768'* ]]
}

@test "gate preserves exact argv and payload exit statuses" {
    run "$ROOT/bin/dev-run" build bash -c 'printf "<%s>\n" "$@"' _ 'two words' '' '*;$(touch nope)'
    [ "$status" = 0 ]
    [[ "$output" == *$'<two words>\n<>\n<*;$(touch nope)>'* ]]
    run "$ROOT/bin/dev-run" heavy bash -c 'exit 7'
    [ "$status" = 7 ]
    [ -z "$(find "$XDG_RUNTIME_DIR" -mindepth 1 -print -quit)" ]
}

@test "nominal machine retains ceilings and smaller machines adapt RAM and CPU" {
    run "$ROOT/bin/dev-run" build true
    [ "$status" = 0 ]
    grep -qx 'CPUQuota=800%' "$FIXTURE/request"
    grep -qx 'MemoryHigh=7516192768' "$FIXTURE/request"
    grep -qx 'MemoryMax=9663676416' "$FIXTURE/request"
    grep -qx 'MemorySwapMax=2147483648' "$FIXTURE/request"
    export RAM_KB=11534336 THREADS=4
    run "$ROOT/bin/dev-run" build true
    [ "$status" = 0 ]
    grep -qx 'CPUQuota=200%' "$FIXTURE/request"
    grep -qx 'MemoryHigh=3758096384' "$FIXTURE/request"
    grep -qx 'MemoryMax=4831838208' "$FIXTURE/request"
    grep -qx 'MemorySwapMax=1073741824' "$FIXTURE/request"
}

@test "emulator refuses adapted cap below a 3 GiB guest" {
    export RAM_KB=4194304 THREADS=1
    run "$ROOT/bin/dev-run" emulator touch "$FIXTURE/sentinel"
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/sentinel" ]
    [ ! -e "$FIXTURE/request" ]
}

@test "every missing unbounded or ineffective kernel control fails closed" {
    for control in cpu.max memory.high memory.max memory.swap.max pids.max; do
        for failure in missing unbounded loose malformed; do
            export FAILURE="${failure}_$control"
            run "$ROOT/bin/dev-run" build touch "$FIXTURE/sentinel"
            [ "$status" != 0 ]
            [ ! -e "$FIXTURE/sentinel" ]
        done
    done
}

@test "missing manager wrong membership and disappearing unit never execute payload" {
    for failure in manager wrong_pid disappear inactive property_MemoryHigh property_MemoryMax property_MemorySwapMax property_TasksMax; do
        export FAILURE=$failure
        rm -f "$FIXTURE/shown"
        run "$ROOT/bin/dev-run" heavy touch "$FIXTURE/sentinel"
        [ "$status" != 0 ]
        [ ! -e "$FIXTURE/sentinel" ]
    done
}

@test "timeout closes the gate and cleans private IPC" {
    export FAILURE=timeout
    run "$ROOT/bin/dev-run" heavy touch "$FIXTURE/sentinel"
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/sentinel" ]
    [ -z "$(find "$XDG_RUNTIME_DIR" -mindepth 1 -print -quit)" ]
}

@test "runtime directory is mandatory and private IPC is removed" {
    unset XDG_RUNTIME_DIR
    run "$ROOT/bin/dev-run" heavy touch "$FIXTURE/sentinel"
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/sentinel" ]
}

@test "user rows are validated as private data and never sourced" {
    mkdir -p "$HOME/.config/vaio-dev"
    printf 'touch %s\n' "$FIXTURE/sentinel" >"$HOME/.config/vaio-dev/profiles.conf"
    chmod 600 "$HOME/.config/vaio-dev/profiles.conf"
    run "$ROOT/bin/dev-run" build true
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/sentinel" ]
    printf 'build\t800\t7\t9\t2\t1024\n' >"$HOME/.config/vaio-dev/profiles.conf"
    chmod 644 "$HOME/.config/vaio-dev/profiles.conf"
    run "$ROOT/bin/dev-run" build true
    [ "$status" != 0 ]
}

@test "mode-0600 incomplete user table is rejected before any workload starts" {
    mkdir -p "$HOME/.config/vaio-dev"
    printf 'build\t800\t7\t9\t2\t1024\n' >"$HOME/.config/vaio-dev/profiles.conf"
    chmod 600 "$HOME/.config/vaio-dev/profiles.conf"

    run "$ROOT/bin/dev-run" emulator touch "$FIXTURE/sentinel"

    [ "$status" != 0 ]
    [[ "$output" == *'Malformed workload profile table'* ]]
    [ ! -e "$FIXTURE/request" ]
    [ ! -e "$FIXTURE/sentinel" ]
}

@test "valid private user rows apply only to the next workload" {
    mkdir -p "$HOME/.config/vaio-dev"
    printf 'build\t200\t2\t3\t0\t128\nemulator\t400\t5\t6\t1\t512\nheavy\t600\t6\t8\t2\t768\n' >"$HOME/.config/vaio-dev/profiles.conf"
    chmod 600 "$HOME/.config/vaio-dev/profiles.conf"
    run "$ROOT/bin/dev-run" build true
    [ "$status" = 0 ]
    grep -qx 'CPUQuota=200%' "$FIXTURE/request"
    grep -qx 'MemoryMax=3221225472' "$FIXTURE/request"
    grep -qx 'MemorySwapMax=0' "$FIXTURE/request"
    grep -qx 'TasksMax=128' "$FIXTURE/request"
}

@test "a disabled flag is never inferred after failed enforcement" {
    export DEV_LIMITS_DISABLED=0 FAILURE=manager
    run "$ROOT/bin/dev-run" heavy touch "$FIXTURE/sentinel"
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/sentinel" ]
    [[ "$output" != *'UNSAFE'* ]]
}

@test "unsafe bypass is explicit and emits an unmistakable warning" {
    export DEV_LIMITS_DISABLED=1 FAILURE=manager
    run "$ROOT/bin/dev-run" heavy bash -c 'exit 7'
    [ "$status" = 7 ]
    [[ "$output" == *'UNSAFE'* ]]
    [ ! -e "$FIXTURE/request" ]
}

@test "interrupted handshake never releases the payload" {
    export FAILURE=timeout
    "$ROOT/bin/dev-run" heavy touch "$FIXTURE/sentinel" >"$FIXTURE/output" 2>&1 &
    launcher=$!
    for ((i = 0; i < 100; i++)); do
        [[ -f "$FIXTURE/request" ]] && break
        sleep .02
    done
    kill -TERM "$launcher"
    wait "$launcher" && result=0 || result=$?
    [ "$result" = 143 ]
    [ ! -e "$FIXTURE/sentinel" ]
    [ -z "$(find "$XDG_RUNTIME_DIR" -mindepth 1 -print -quit)" ]
}

@test "payload self termination returns its signal status" {
    run "$ROOT/bin/dev-run" heavy bash -c 'kill -TERM $$'
    [ "$status" = 143 ]
}

@test "non-sticky group or world writable runtime directories refuse before launching a scope" {
    for mode in 0770 0707 0777; do
        chmod "$mode" "$XDG_RUNTIME_DIR"
        run "$ROOT/bin/dev-run" heavy touch "$FIXTURE/sentinel"
        [ "$status" != 0 ]
        [ ! -e "$FIXTURE/sentinel" ]
        [ ! -e "$FIXTURE/request" ]
    done
}

@test "an unsafe writable ancestor cannot hide behind a private runtime leaf" {
    mkdir -p "$FIXTURE/shared/runtime"
    chmod 777 "$FIXTURE/shared"
    chmod 700 "$FIXTURE/shared/runtime"
    export XDG_RUNTIME_DIR="$FIXTURE/shared/runtime"
    run "$ROOT/bin/dev-run" heavy touch "$FIXTURE/sentinel"
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/sentinel" ]
    [ ! -e "$FIXTURE/request" ]
}

@test "sticky shared runtime directories protect the private IPC entry" {
    chmod 1777 "$XDG_RUNTIME_DIR"
    run "$ROOT/bin/dev-run" heavy true
    [ "$status" = 0 ]
    [ -z "$(find "$XDG_RUNTIME_DIR" -mindepth 1 -print -quit)" ]
}

@test "runtime aliases use a canonical path with safe ancestors" {
    mkdir -p "$FIXTURE/shared"
    chmod 777 "$FIXTURE/shared"
    ln -s "$FIXTURE/shared" "$FIXTURE/alias"
    mkdir "$FIXTURE/shared/runtime"
    chmod 700 "$FIXTURE/shared/runtime"
    export XDG_RUNTIME_DIR="$FIXTURE/alias/runtime"
    run "$ROOT/bin/dev-run" heavy touch "$FIXTURE/sentinel"
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/sentinel" ]
    [ ! -e "$FIXTURE/request" ]
    chmod 700 "$FIXTURE/shared"
    run "$ROOT/bin/dev-run" heavy true
    [ "$status" = 0 ]
    grep -Fq "$FIXTURE/shared/runtime/dev-run." "$FIXTURE/request"
    ! grep -Fq "$FIXTURE/alias/" "$FIXTURE/request"
}

@test "balanced choice is read by future dev-run scopes only" {
    mkdir -p "$HOME/.config/vaio-dev"
    printf 'balanced\n' >"$HOME/.config/vaio-dev/profile"
    chmod 600 "$HOME/.config/vaio-dev/profile"
    run "$ROOT/bin/dev-run" build true
    [ "$status" = 0 ]
    grep -Fq 'CPUQuota=800%' "$FIXTURE/request"
    grep -Fq 'MemoryMax=9663676416' "$FIXTURE/request"
}

@test "invalid selected preset stops before creating a workload scope" {
    mkdir -p "$HOME/.config/vaio-dev"
    printf 'throughput\n' >"$HOME/.config/vaio-dev/profile"
    chmod 600 "$HOME/.config/vaio-dev/profile"
    run "$ROOT/bin/dev-run" build touch "$FIXTURE/sentinel"
    [ "$status" != 0 ]
    [[ "$output" == *"Invalid user profile choice"* ]]
    [ ! -e "$FIXTURE/request" ]
    [ ! -e "$FIXTURE/sentinel" ]
}
