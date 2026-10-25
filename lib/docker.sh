#!/usr/bin/env bash

_DOCKER_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/packages.sh
source "$_DOCKER_LIB/packages.sh"

_docker_service_state() {
    local output key value load='' state=''
    output=$(systemctl --system show docker.service --property=LoadState --property=UnitFileState --property=ActiveState 2>/dev/null) || {
        return 1
    }
    while IFS='=' read -r key value; do
        case $key in
            LoadState) load=$value ;;
            UnitFileState) DOCKER_SERVICE_ENABLED=$value ;;
            ActiveState) state=$value ;;
        esac
    done <<<"$output"
    if [[ $load == not-found ]]; then
        DOCKER_SERVICE_PRESENT=no
        DOCKER_SERVICE_ENABLED=disabled
        DOCKER_SERVICE_ACTIVE=false
        return 0
    fi
    [[ $load == loaded && $DOCKER_SERVICE_ENABLED =~ ^(enabled|disabled|masked|static)$ && $state =~ ^(active|inactive)$ ]] || return 1
    DOCKER_SERVICE_PRESENT=yes
    [[ $state == active ]] && DOCKER_SERVICE_ACTIVE=true || DOCKER_SERVICE_ACTIVE=false
}

_docker_socket_state() {
    local output key value load='' unit_file='' state=''
    output=$(systemctl --system show docker.socket --property=LoadState --property=UnitFileState --property=ActiveState 2>/dev/null) || return 1
    while IFS='=' read -r key value; do
        case $key in
            LoadState) load=$value ;;
            UnitFileState) unit_file=$value ;;
            ActiveState) state=$value ;;
        esac
    done <<<"$output"
    if [[ $load == not-found ]]; then
        [[ $state == inactive ]] || return 1
        DOCKER_SOCKET_PRESENT=no
        return 0
    fi
    [[ $load == loaded && $unit_file =~ ^(enabled|disabled|masked|static|indirect|generated|linked|linked-runtime|disabled-runtime)$ && $state =~ ^(active|inactive)$ ]] || return 1
    DOCKER_SOCKET_PRESENT=yes
}

_docker_user_service_present() {
    local line
    DOCKER_USER_SERVICE_PRESENT=no
    while IFS= read -r line; do
        if [[ $line == user:docker.service ]]; then
            DOCKER_USER_SERVICE_PRESENT=yes
            return 0
        fi
    done <<<"${PREFLIGHT_SERVICES:-}"
}

_docker_engine_state() {
    local info driver version security uid group controllers subtree controller
    DOCKER_ENGINE_STATE=unavailable
    DOCKER_ROOTLESS=unknown
    DOCKER_CGROUP_STATUS=not-applicable
    DOCKER_WARNING=''
    command -v docker >/dev/null || return 0
    if ! info=$(docker info --format '{{.CgroupDriver}}|{{.CgroupVersion}}|{{json .SecurityOptions}}' 2>/dev/null); then
        return 0
    fi
    [[ $info == *'|'*'|'* ]] || return 0
    IFS='|' read -r driver version security <<<"$info"
    DOCKER_ENGINE_STATE=available
    if [[ $security == *rootless* ]]; then
        DOCKER_ROOTLESS=yes
        if [[ $driver != systemd || $version != 2 ]]; then
            DOCKER_CGROUP_STATUS=ineffective
        else
            uid=$(id -u) || return 0
            group="/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service"
            [[ -r $group/cgroup.controllers && -r $group/cgroup.subtree_control ]] || {
                DOCKER_CGROUP_STATUS=unknown
                DOCKER_WARNING='warning=rootless resource limits may be ineffective: delegated controllers are unknown'
                return 0
            }
            controllers=$(<"$group/cgroup.controllers")
            subtree=$(<"$group/cgroup.subtree_control")
            DOCKER_CGROUP_STATUS=effective
            for controller in cpu memory pids; do
                if [[ " $controllers " != *" $controller "* || " $subtree " != *" $controller "* ]]; then
                    DOCKER_CGROUP_STATUS=ineffective
                    break
                fi
            done
        fi
        if [[ $DOCKER_CGROUP_STATUS != effective ]]; then
            DOCKER_WARNING='warning=rootless resource limits may be ineffective'
        fi
    else
        DOCKER_ROOTLESS=no
    fi
}

docker_plan() {
    local packages apt_token signature existing_provider
    preflight_install_inventory || {
        printf 'Error: package and service inventory is unknown; Docker plan refused.\n' >&2
        return 1
    }
    _docker_engine_state
    _docker_service_state || {
        printf 'Error: Docker service state is unknown; refusing an installation plan.\n' >&2
        return 1
    }
    _docker_socket_state || {
        printf 'Error: Docker socket state is unknown; refusing package operations.\n' >&2
        return 1
    }
    _apt_barrier docker || return 1
    existing_provider=$APT_DOCKER_PROVIDER
    packages=$(package_selection docker) || return 1
    DOCKER_PLAN_PACKAGES=()
    if [[ -n $packages ]]; then mapfile -t DOCKER_PLAN_PACKAGES <<<"$packages"; fi
    DOCKER_PLAN_PROVIDER=$APT_DOCKER_PROVIDER
    [[ $DOCKER_PLAN_PROVIDER != none ]] || DOCKER_PLAN_PROVIDER=distro
    _docker_user_service_present
    if [[ $DOCKER_ENGINE_STATE == available || $existing_provider != none || $DOCKER_USER_SERVICE_PRESENT == yes || $DOCKER_SOCKET_PRESENT == yes ]]; then
        DOCKER_PLAN_ACTION=preserve
    elif [[ $DOCKER_SERVICE_PRESENT == yes ]]; then
        DOCKER_PLAN_ACTION=manual
    else
        DOCKER_PLAN_ACTION=install
    fi
    APT_PLAN_TOKEN=''
    if [[ $DOCKER_PLAN_ACTION == install ]]; then
        ((${#DOCKER_PLAN_PACKAGES[@]})) || return 1
        apt_plan docker "${DOCKER_PLAN_PACKAGES[@]}" || return 1
        apt_token=$APT_PLAN_TOKEN
    else
        apt_token=none
    fi
    signature=$(_apt_signature docker "$DOCKER_PLAN_ACTION" "$DOCKER_PLAN_PROVIDER" "${DOCKER_PLAN_PACKAGES[*]}" "$PREFLIGHT_PACKAGES" "$PREFLIGHT_SERVICES" "$DOCKER_ENGINE_STATE" "$DOCKER_ROOTLESS" "$DOCKER_CGROUP_STATUS" "$apt_token")
    DOCKER_PLAN_TOKEN=$signature
    printf 'provider=%s\nengine=%s\nrootless=%s\ncgroup_limits=%s\naction=%s\npackages=%s\nuser_service=%s\n' \
        "$DOCKER_PLAN_PROVIDER" "$DOCKER_ENGINE_STATE" "$DOCKER_ROOTLESS" "$DOCKER_CGROUP_STATUS" "$DOCKER_PLAN_ACTION" "${DOCKER_PLAN_PACKAGES[*]:-none}" "$DOCKER_USER_SERVICE_PRESENT"
    [[ -z $DOCKER_WARNING ]] || printf '%s\n' "$DOCKER_WARNING"
    printf 'plan_token=%s\n' "$DOCKER_PLAN_TOKEN"
}

_docker_service_event() {
    local run=$1 status=$2 before_enabled=$3 before_active=$4 applied_enabled=$5 applied_active=$6
    python3 "$_DOCKER_LIB/manifest.py" append "$run" \
        "{\"event\":\"service\",\"module\":\"docker\",\"unit\":\"docker.service\",\"scope\":\"system\",\"status\":\"$status\",\"before_enabled\":\"$before_enabled\",\"before_active\":$before_active,\"applied_enabled\":\"$applied_enabled\",\"applied_active\":$applied_active}"
}

docker_apply() {
    local run=${1:-} selection=${2:-} confirmation=${3:-} token=${4:-} apt_token service_before_enabled service_before_active
    [[ -n $run && $selection == --docker && $confirmation == --confirmed && -n $token ]] || {
        printf 'Error: docker_apply requires explicit selection and confirmation.\n' >&2
        return 2
    }
    docker_plan >/dev/null || return 1
    [[ $token == "$DOCKER_PLAN_TOKEN" ]] || {
        printf 'Error: Docker state or plan changed; review the preview again.\n' >&2
        return 1
    }
    if [[ $DOCKER_PLAN_ACTION == preserve ]]; then
        printf 'Docker already exists; existing provider and service preserved.\n'
        [[ -z $DOCKER_WARNING ]] || printf '%s\n' "$DOCKER_WARNING"
        return 0
    fi
    if [[ $DOCKER_PLAN_ACTION != install ]]; then
        printf 'Error: Docker service exists without a recognized package provider; manual review required.\n' >&2
        return 1
    fi
    service_before_enabled=$DOCKER_SERVICE_ENABLED
    service_before_active=$DOCKER_SERVICE_ACTIVE
    [[ $DOCKER_SERVICE_PRESENT == no && $service_before_active == false ]] || return 1
    apt_token=$APT_PLAN_TOKEN
    _docker_service_event "$run" intent "$service_before_enabled" "$service_before_active" enabled true || return 1
    apt_apply "$run" docker --confirmed "$apt_token" "${DOCKER_PLAN_PACKAGES[@]}" || return 1
    sudo systemctl --system enable --now docker.service || return 1
    _docker_service_state || return 1
    [[ $DOCKER_SERVICE_PRESENT == yes && $DOCKER_SERVICE_ENABLED == enabled && $DOCKER_SERVICE_ACTIVE == true ]] || {
        printf 'Error: Docker service did not reach the approved enabled/active state.\n' >&2
        return 1
    }
    _docker_service_event "$run" applied "$service_before_enabled" "$service_before_active" "$DOCKER_SERVICE_ENABLED" "$DOCKER_SERVICE_ACTIVE"
}
