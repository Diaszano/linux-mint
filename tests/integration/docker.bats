#!/usr/bin/env bats
# Integration tests run only in the disposable VM. Set DOCKER_TEST_INSTALL=1 to
# authorize package installation inside that VM; never set it on the VAIO host.

setup() {
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    project="vaio-docker-test-${BATS_TEST_NUMBER:-0}"
    export POSTGRES_PASSWORD='vm-only-compose-password'
}

teardown() {
    if command -v docker >/dev/null && sudo docker info >/dev/null 2>&1; then
        sudo env POSTGRES_PASSWORD="$POSTGRES_PASSWORD" docker compose -p "$project" -f "$ROOT/examples/compose-limits.example.yaml" down -v >/dev/null 2>&1 || true
    fi
}

@test "explicit Docker apply exposes only localhost and enforces Compose service limits" {
    if ! sudo docker info >/dev/null 2>&1; then
        if [[ ${DOCKER_TEST_INSTALL:-0} != 1 ]]; then
            echo 'NOT INSTALLED: set DOCKER_TEST_INSTALL=1 only in the disposable VM to exercise installation.' >&2
            skip 'Docker not installed in disposable VM'
        fi
        run bash -c '
            set -euo pipefail
            source "$1/lib/backup.sh"
            source "$1/lib/packages.sh"
            source "$1/lib/docker.sh"
            docker_plan
            run_id=$(begin_run)
            docker_apply "$run_id" --docker --confirmed "$DOCKER_PLAN_TOKEN"
        ' _ "$ROOT"
        [ "$status" -eq 0 ]
    fi

    local config json
    config=$(sudo env POSTGRES_PASSWORD="$POSTGRES_PASSWORD" docker compose -p "$project" -f "$ROOT/examples/compose-limits.example.yaml" config -q)
    sudo env POSTGRES_PASSWORD="$POSTGRES_PASSWORD" docker compose -p "$project" -f "$ROOT/examples/compose-limits.example.yaml" up -d
    for _ in {1..60}; do
        if sudo env POSTGRES_PASSWORD="$POSTGRES_PASSWORD" docker compose -p "$project" -f "$ROOT/examples/compose-limits.example.yaml" ps --status running --quiet | grep -q .; then
            break
        fi
        sleep 2
    done
    [ "$(sudo env POSTGRES_PASSWORD="$POSTGRES_PASSWORD" docker compose -p "$project" -f "$ROOT/examples/compose-limits.example.yaml" ps --status running --quiet | wc -l)" -eq 2 ]

    json=$(sudo docker inspect "${project}-db-1" "${project}-cache-1" --format '{{.HostConfig.NanoCpus}} {{.HostConfig.Memory}} {{.HostConfig.PidsLimit}} {{range .HostConfig.PortBindings}}{{(index . 0).HostIp}}{{end}}')
    printf 'container_limits=%s\n' "$json"
    [[ "$json" == *'1000000000 1073741824 256 127.0.0.1'* ]]
    [[ "$json" == *'500000000 536870912 128 127.0.0.1'* ]]
    sudo docker stats --no-stream --format '{{.Name}} cpu={{.CPUPerc}} memory={{.MemUsage}} pids={{.PIDs}}' "${project}-db-1" "${project}-cache-1"
}

