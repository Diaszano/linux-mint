#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    FIXTURE="$BATS_TEST_TMPDIR"
    export ROOT FIXTURE
    export HOME="$FIXTURE/home" XDG_STATE_HOME="$FIXTURE/state"
    export PACKAGE_LOG="$FIXTURE/apt.log" SIMULATION_LOG="$FIXTURE/apt-simulate.log"
    mkdir -p "$HOME" "$FIXTURE/bin"
    export PATH="$FIXTURE/bin:$PATH"
    printf 'bash\tinstall ok installed\t5.2\n' >"$FIXTURE/packages"
    : >"$FIXTURE/units"
    : >"$FIXTURE/swaps"
    cat >"$FIXTURE/bin/probe" <<'SH'
#!/usr/bin/env bash
command_name=${0##*/}
case "$command_name" in
    dpkg-query)
        cat "$FIXTURE/packages"
        ;;
    swapon)
        cat "$FIXTURE/swaps"
        ;;
    zramctl)
        exit 0
        ;;
    systemctl)
        args=" $* "
        if [[ $args == *list-units* || $args == *list-unit-files* ]]; then
            cat "$FIXTURE/units"
        elif [[ $args == *' show '* && $args == *docker.socket* ]]; then
            if [[ -e $FIXTURE/socket-active ]]; then
                printf 'Id=docker.socket\nLoadState=not-found\nUnitFileState=\nActiveState=active\n'
            else
                printf 'Id=docker.socket\nLoadState=not-found\nUnitFileState=\nActiveState=inactive\n'
            fi
        elif [[ $args == *' show '* && $args == *docker.service* ]]; then
            if [[ -e $FIXTURE/docker-unit ]]; then
                printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\n'
            else
                printf 'LoadState=not-found\nUnitFileState=disabled\nActiveState=inactive\n'
            fi
        elif [[ $args == *' enable '* ]]; then
            printf '%s\n' "$*" >>"$FIXTURE/systemctl.log"
            touch "$FIXTURE/docker-unit"
            printf 'docker.service enabled active\n' >"$FIXTURE/units"
        else
            printf '%s\n' "$*" >>"$FIXTURE/systemctl.log"
        fi
        ;;
    apt-get)
        if [[ $* == *--simulate* ]]; then
            printf '%s\n' "$*" >>"$SIMULATION_LOG"
            if [[ -e $FIXTURE/simulation-output ]]; then
                cat "$FIXTURE/simulation-output"
                exit 0
            fi
            printf 'Inst docker.io (26.1 Ubuntu:24.04/noble [amd64])\nInst docker-compose-v2 (2.27 Ubuntu:24.04/noble [amd64])\n'
        else
            printf '%s\n' "$*" >>"$PACKAGE_LOG"
            printf 'docker.io\tinstall ok installed\t26.1\ndocker-compose-v2\tinstall ok installed\t2.27\n' >>"$FIXTURE/packages"
        fi
        ;;
    docker)
        [[ -e $FIXTURE/docker-info ]] || exit 1
        cat "$FIXTURE/docker-info"
        ;;
    sudo)
        exec env "$@"
        ;;
esac
exit 0
SH
    chmod +x "$FIXTURE/bin/probe"
    for name in dpkg-query swapon zramctl systemctl apt-get docker sudo; do
        ln -s "$FIXTURE/bin/probe" "$FIXTURE/bin/$name"
    done
}

docker_library() {
    bash -c 'source "$ROOT/lib/backup.sh"; source "$ROOT/lib/preflight.sh"; source "$ROOT/lib/packages.sh"; source "$ROOT/lib/docker.sh"; eval "$1"' _ "$1"
}

@test "Docker plan selects distro packages without installation or service writes" {
    run docker_library 'docker_plan'
    [ "$status" -eq 0 ]
    [[ "$output" == *'provider=distro'* ]]
    [[ "$output" == *'docker.io docker-compose-v2'* ]]
    [[ "$output" == *'action=install'* ]]
    [ ! -e "$PACKAGE_LOG" ]
    [ ! -e "$FIXTURE/systemctl.log" ]
}

@test "conflicting Docker CE and distro packages fail closed before writes" {
    printf 'docker-ce\tinstall ok installed\t5:27.0\ndocker.io\tinstall ok installed\t29.1\n' >>"$FIXTURE/packages"
    run docker_library 'docker_plan'
    [ "$status" -ne 0 ]
    [ ! -e "$PACKAGE_LOG" ]
    [ ! -e "$FIXTURE/systemctl.log" ]
}

@test "APT simulation cannot mix CE dependencies into the default distro plan" {
    printf 'Inst docker-ce (5:27.0 Ubuntu:24.04/noble [amd64])\n' >"$FIXTURE/simulation-output"
    run docker_library 'docker_plan'
    [ "$status" -ne 0 ]
    [ ! -e "$PACKAGE_LOG" ]
    [ ! -e "$FIXTURE/systemctl.log" ]
}

@test "active orphan Docker socket makes Docker planning fail closed" {
    touch "$FIXTURE/socket-active"
    run docker_library 'docker_plan'
    [ "$status" -ne 0 ]
    [[ "$output" == *'Docker socket state is unknown'* ]]
    [ ! -e "$PACKAGE_LOG" ]
    [ ! -e "$FIXTURE/systemctl.log" ]
}

@test "rootless engine with ineffective cgroup settings warns in its plan" {
    printf 'none|1|["name=rootless"]\n' >"$FIXTURE/docker-info"
    run docker_library 'docker_plan'
    [ "$status" -eq 0 ]
    [[ "$output" == *'rootless=yes'* ]]
    [[ "$output" == *'warning=rootless resource limits may be ineffective'* ]]
    [ ! -e "$PACKAGE_LOG" ]
}

@test "Docker apply requires explicit selection and a matching token" {
    run docker_library 'docker_plan; docker_apply unused --confirmed "$DOCKER_PLAN_TOKEN"'
    [ "$status" -ne 0 ]
    [ ! -e "$PACKAGE_LOG" ]
    run docker_library 'docker_plan; docker_apply unused --docker --confirmed wrong-token'
    [ "$status" -ne 0 ]
    [ ! -e "$PACKAGE_LOG" ]
}

@test "confirmed Docker apply journals package and before/after service state" {
    run docker_library '
        run_id=$(begin_run)
        docker_plan
        token=$DOCKER_PLAN_TOKEN
        docker_apply "$run_id" --docker --confirmed "$token"
        python3 - "$run_id" <<"PY"
import json, os, pathlib, sys
run = pathlib.Path(os.environ["XDG_STATE_HOME"]) / "vaio-fe16-dev-setup/runs" / sys.argv[1]
events = [json.loads(line) for line in (run / "manifest.jsonl").read_text().splitlines()]
service = [event for event in events if event.get("event") == "service"]
assert [event["status"] for event in service] == ["intent", "applied"]
assert service[0]["before_enabled"] == "disabled" and service[0]["before_active"] is False
assert service[-1]["applied_enabled"] == "enabled" and service[-1]["applied_active"] is True
assert any(event.get("event") == "package" and event["package"] == "docker.io" for event in events)
PY
    '
    [ "$status" -eq 0 ]
    [ -e "$FIXTURE/docker-unit" ]
    [ "$(wc -l <"$FIXTURE/systemctl.log")" -eq 1 ]
    [ "$(wc -l <"$PACKAGE_LOG")" -eq 1 ]
    [ "$(wc -l <"$SIMULATION_LOG")" -ge 1 ]
}

@test "existing Docker provider is preserved without reinstall or service start" {
    printf 'docker.io\tinstall ok installed\t26.1\n' >>"$FIXTURE/packages"
    touch "$FIXTURE/docker-unit"
    printf 'systemd|2|[]\n' >"$FIXTURE/docker-info"
    run docker_library 'docker_plan; docker_apply unused --docker --confirmed "$DOCKER_PLAN_TOKEN"'
    [ "$status" -eq 0 ]
    [[ "$output" == *'existing provider and service preserved'* ]]
    [ ! -e "$PACKAGE_LOG" ]
    [ ! -e "$FIXTURE/systemctl.log" ]
}

@test "Compose example binds localhost and requires a secret environment variable" {
    compose="$ROOT/examples/compose-limits.example.yaml"
    [ -f "$compose" ]
    grep -Fq '127.0.0.1:' "$compose"
    grep -Fq 'cpus:' "$compose"
    grep -Fq 'mem_limit:' "$compose"
    grep -Fq 'pids_limit:' "$compose"
    grep -Eq 'POSTGRES_PASSWORD:[[:space:]]*"\$\{POSTGRES_PASSWORD:\?' "$compose"
}
