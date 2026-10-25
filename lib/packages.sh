#!/usr/bin/env bash

_PACKAGES_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/preflight.sh
source "$_PACKAGES_LIB/preflight.sh"

package_selection() {
  case "$1" in
    baseline)
      printf '%s\n' ca-certificates curl wget gnupg git git-lfs build-essential \
        autoconf automake libtool cmake ninja-build pkg-config libssl-dev libffi-dev \
        zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev liblzma-dev libncurses-dev \
        libxml2-dev libpq-dev xz-utils unzip zip jq ripgrep fzf fd-find tree \
        python3 python3-venv pipx htop btop sysstat lm-sensors mesa-utils \
        mesa-vulkan-drivers vulkan-tools smartmontools nvme-cli powertop iotop
      ;;
    kvm) printf '%s\n' qemu-kvm cpu-checker libvirt-daemon-system libvirt-clients virt-manager ;;
    zram) printf '%s\n' zram-tools ;;
    earlyoom) printf '%s\n' earlyoom ;;
    mise)
      local mise_target=${HOME:-}/.local/bin/mise
      if [[ -e $mise_target || -L $mise_target ]]; then
        [[ -f $mise_target && -x $mise_target && ! -L $mise_target ]] && return 0
        return 1
      fi
      [[ -n $(type -P mise 2>/dev/null) ]] && return 0
      command -v minisign >/dev/null || printf '%s\n' minisign
      ;;
    docker)
      _apt_barrier docker || return 1
      if [[ $APT_DOCKER_PROVIDER == ce ]]; then
        printf '%s\n' docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      else
        printf '%s\n' docker.io docker-compose-v2
      fi
      ;;
    *)
      printf 'Error: unknown package module: %s\n' "$1" >&2
      return 1
      ;;
  esac
}

_apt_installed() {
  local package status
  while IFS=$'\t' read -r package status _; do
    [[ ${package%%:*} == "$1" && $status == *' ok installed' ]] && return 0
  done <<<"$PREFLIGHT_PACKAGES"
  return 1
}

_apt_memory_manager() {
  case "${1%%:*}" in
    *zram* | *zswap* | systemd-swap | swapspace | dphys-swapfile) printf 'zram\n' ;;
    earlyoom | systemd-oomd | oomd | nohang | low-memory-monitor) printf 'earlyoom\n' ;;
    *) printf 'none\n' ;;
  esac
}

_apt_barrier() {
  local module=$1 package status evidence device type size priority extra service_line skip_line=no requested=none candidate
  preflight_install_inventory || {
    printf 'Error: package, swap, or service inventory is indeterminate.\n' >&2
    return 1
  }
  evidence=${PREFLIGHT_SERVICES,,}
  if [[ ${APT_MEMORY_MASKED_UNIT:-} == zramswap.service ]]; then
    evidence=''
    while IFS= read -r service_line; do
      if [[ $service_line == system:* || $service_line == user:* ]]; then
        skip_line=no
        [[ $service_line == "system:${APT_MEMORY_MASKED_UNIT}" ]] && skip_line=yes
      fi
      [[ $skip_line == yes ]] && continue
      evidence+="$service_line"$'\n'
    done <<<"${PREFLIGHT_SERVICES,,}"
  fi
  while IFS=$'\t' read -r package status _; do
    [[ $status == *' ok installed' ]] || continue
    case "$module:$(_apt_memory_manager "$package")" in
      zram:zram | earlyoom:earlyoom)
        printf 'Error: existing manager blocks %s: %s\n' "$module" "$package" >&2
        return 1
        ;;
    esac
  done <<<"$PREFLIGHT_PACKAGES"
  while read -r device type size priority extra; do
    [[ -n $device ]] || continue
    if [[ -n $extra && $size =~ ^[0-9]+([.,][0-9]+)?[KMGTPEB]?$ && $priority =~ ^[0-9]+([.,][0-9]+)?[KMGTPEB]?$ && $extra =~ ^-?[0-9]+$ ]]; then
      priority=$extra
      extra=''
    fi
    [[ $device == /* && -n $type && $size =~ ^[0-9]+([.,][0-9]+)?[KMGTPEB]?$ && $priority =~ ^-?[0-9]+$ && -z $extra ]] || {
      printf 'Error: swap state is indeterminate.\n' >&2
      return 1
    }
    if [[ $module == zram ]] && ((priority >= 100)); then
      printf 'Error: existing swap priority conflicts with the proposed zram policy.\n' >&2
      return 1
    fi
  done <<<"$PREFLIGHT_SWAPS"
  case "$module" in
    zram)
      if [[ -n $PREFLIGHT_ZRAM || ${PREFLIGHT_SWAPS,,} == *zram* || $evidence =~ (zram|zswap|zramswap|swap-policy) ]]; then
        printf 'Error: existing swap or zram unit found; migration requires review.\n' >&2
        return 1
      fi
      ;;
    earlyoom)
      if [[ $evidence =~ (earlyoom|oomd|nohang|low-memory-monitor|oom-manager) ]]; then
        printf 'Error: an existing OOM unit was found; preserve the current policy.\n' >&2
        return 1
      fi
      ;;
  esac
  local ce=no distro=no
  for package in docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin; do
    if _apt_installed "$package"; then ce=yes; fi
  done
  for package in docker.io docker-compose-v2 containerd runc; do
    if _apt_installed "$package"; then distro=yes; fi
  done
  APT_DOCKER_PROVIDER=none
  [[ $ce != yes ]] || APT_DOCKER_PROVIDER=ce
  [[ $distro != yes ]] || APT_DOCKER_PROVIDER=distro
  if [[ $module == docker && $ce == yes && $distro == yes ]]; then
    printf 'Error: Docker CE and distribution providers conflict.\n' >&2
    return 1
  fi
  for package in "$@"; do
    case "$package" in
      docker.io | docker-compose-v2 | containerd | runc) candidate=distro ;;
      docker-ce | docker-ce-cli | containerd.io | docker-compose-plugin | docker-buildx-plugin) candidate=ce ;;
      *) continue ;;
    esac
    if [[ $requested != none && $requested != "$candidate" ]]; then
      printf 'Error: requested Docker packages mix providers.\n' >&2
      return 1
    fi
    requested=$candidate
  done
  if [[ $module == docker && $requested != none ]]; then
    if [[ $APT_DOCKER_PROVIDER != none && $APT_DOCKER_PROVIDER != "$requested" ]]; then
      printf 'Error: requested Docker provider conflicts with the installed provider.\n' >&2
      return 1
    fi
    APT_DOCKER_PROVIDER=$requested
  fi
  shift
  for package in "$@"; do
    case "$package" in
      docker.io | docker-compose-v2 | containerd | runc)
        [[ $ce == no ]] || {
          printf 'Error: preserve the Docker CE provider.\n' >&2
          return 1
        }
        ;;
      docker-ce | docker-ce-cli | containerd.io | docker-compose-plugin | docker-buildx-plugin)
        [[ $distro == no ]] || {
          printf 'Error: preserve the distribution Docker provider.\n' >&2
          return 1
        }
        ;;
    esac
  done
}

_apt_signature() {
  printf '%s\0' "$@" | sha256sum | cut -d' ' -f1
}

apt_plan() {
  local module=${1:-} package line name
  APT_PLAN_TOKEN=''
  APT_PLAN_CONFIG=${APT_CONFIG:-}
  APT_PLAN_MISSING=()
  [[ $module =~ ^[a-z][a-z0-9_-]{0,63}$ && $# -gt 1 ]] || return 1
  shift
  for package in "$@"; do
    [[ $package =~ ^[a-z0-9][a-z0-9+.-]*$ ]] || return 1
    case "$module:$package:$(_apt_memory_manager "$package")" in
      zram:zram-tools:zram | earlyoom:earlyoom:earlyoom | *:*:none) ;;
      *)
        printf 'Error: manager is outside the selected module.\n' >&2
        return 1
        ;;
    esac
  done
  _apt_barrier "$module" "$@" || return 1
  for package in "$@"; do
    if ! _apt_installed "$package"; then APT_PLAN_MISSING+=("$package"); fi
  done
  APT_PLAN_TRANSACTION=''
  if ((${#APT_PLAN_MISSING[@]})); then
    APT_PLAN_TRANSACTION=$(APT_CONFIG="$APT_PLAN_CONFIG" LC_ALL=C apt-get --simulate --no-install-recommends --no-remove --no-upgrade install "${APT_PLAN_MISSING[@]}" 2>&1) || {
      printf 'Error: APT simulation failed; check package indexes and network connectivity.\n%s\n' "$APT_PLAN_TRANSACTION" >&2
      return 1
    }
    while IFS= read -r line; do
      if [[ $line =~ ^Inst[[:space:]]+[^[:space:]]+[[:space:]]+\[ ]]; then
        printf 'Error: transaction attempts to upgrade an installed package.\n' >&2
        return 1
      fi
      case "$line" in
        Remv\ *)
          printf 'Error: transaction attempts to remove an installed package.\n' >&2
          return 1
          ;;
        Inst\ *)
          read -r _ name _ <<<"$line"
          case "$APT_DOCKER_PROVIDER:${name%%:*}" in
            ce:docker.io | ce:docker-compose-v2 | ce:containerd | ce:runc | distro:docker-ce | distro:docker-ce-cli | distro:containerd.io | distro:docker-compose-plugin | distro:docker-buildx-plugin)
              printf 'Error: dependency resolution mixes Docker providers.\n' >&2
              return 1
              ;;
          esac
          case "$module:${name%%:*}:$(_apt_memory_manager "$name")" in
            zram:zram-tools:zram | earlyoom:earlyoom:earlyoom | *:*:none) ;;
            *)
              printf 'Error: dependency resolution includes an unselected manager.\n' >&2
              return 1
              ;;
          esac
          ;;
      esac
    done <<<"$APT_PLAN_TRANSACTION"
    printf '%s\n' "$APT_PLAN_TRANSACTION"
  fi
  APT_PLAN_REQUEST=$(_apt_signature "$module" "$@" "$APT_PLAN_CONFIG")
  APT_PLAN_INVENTORY=$(_apt_signature "$PREFLIGHT_PACKAGES" "$PREFLIGHT_CONFLICT_SERVICES" "$PREFLIGHT_SWAPS" "$PREFLIGHT_ZRAM")
  APT_PLAN_TOKEN=$(_apt_signature "$APT_PLAN_REQUEST" "$APT_PLAN_INVENTORY" "$APT_PLAN_TRANSACTION")
  printf 'missing=%s\nplan_token=%s\n' "${APT_PLAN_MISSING[*]:-none}" "$APT_PLAN_TOKEN"
}

_apt_audit() {
  local run=$1 module=$2 phase=$3 result=$4
  {
    printf '[packages_state]\n%s\n[packages]\n%s\n[services]\n%s\n[swap]\n%s\n[zram]\n%s\n[simulation]\n%s\n' \
      "$PREFLIGHT_PACKAGES_STATE" "$PREFLIGHT_PACKAGES" "$PREFLIGHT_SERVICES" "$PREFLIGHT_SWAPS" "$PREFLIGHT_ZRAM" "$APT_PLAN_TRANSACTION"
  } | python3 -c '
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location("manifest", sys.argv[1] + "/manifest.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
run, module, phase, result = sys.argv[2:]
if not __import__("re").fullmatch(r"[a-z][a-z0-9_-]{0,63}", module):
    raise ValueError("invalid module")
if phase not in ("before", "after"):
    raise ValueError("invalid phase")
data = json.dumps(dict(module=module, phase=phase, apt_exit=int(result), inventory=sys.stdin.read())).encode() + b"\n"
with m.journal(run), m.parent_fd(m.run_path(run) + "/packages-" + module + "-" + phase + ".json") as (parent, name):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
    try:
        with os.fdopen(fd, "wb", closefd=False) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(fd)
        os.fsync(parent)
    finally:
        os.close(fd)
' "$_PACKAGES_LIB" "$run" "$module" "$phase" "$result"
}

# Call only after displaying apt_plan output and explicitly confirming its token.
apt_apply() {
  local run=${1:-} module=${2:-} token=${4:-} result=0 apt_result package installed before_inventory simulation
if [[ $module == earlyoom ]]; then
printf 'Error: earlyoom installation is blocked until constrained-build kill priority is guaranteed.\n' >&2
return 1
fi
  [[ $# -ge 5 && ${3:-} == --confirmed && -n ${APT_PLAN_TOKEN:-} && $token == "$APT_PLAN_TOKEN" ]] || {
    printf 'Error: applying changes requires the confirmed preview.\n' >&2
    return 1
  }
  shift 4
  [[ $(_apt_signature "$module" "$@" "${APT_CONFIG:-}") == "$APT_PLAN_REQUEST" ]] || return 1
  _apt_barrier "$module" "$@" || return 1
  [[ $(_apt_signature "$PREFLIGHT_PACKAGES" "$PREFLIGHT_CONFLICT_SERVICES" "$PREFLIGHT_SWAPS" "$PREFLIGHT_ZRAM") == "$APT_PLAN_INVENTORY" ]] || {
    printf 'Error: state changed after preview; simulate and confirm again.\n' >&2
    return 1
  }
  ((${#APT_PLAN_MISSING[@]})) || return 0
  simulation=$(APT_CONFIG="$APT_PLAN_CONFIG" LC_ALL=C apt-get --simulate --no-install-recommends --no-remove --no-upgrade install "${APT_PLAN_MISSING[@]}" 2>&1) || {
    printf 'Error: new APT simulation failed; no installation was started.\n' >&2
    return 1
  }
  [[ $simulation == "$APT_PLAN_TRANSACTION" ]] || {
    printf 'Error: APT transaction changed; simulate and confirm again.\n' >&2
    return 1
  }
  before_inventory=$PREFLIGHT_PACKAGES
  _apt_audit "$run" "$module" before 0 || return 1
  # Recheck after durable auditing, immediately before maintainer scripts can run.
  _apt_barrier "$module" "$@" || return 1
  [[ $(_apt_signature "$PREFLIGHT_PACKAGES" "$PREFLIGHT_CONFLICT_SERVICES" "$PREFLIGHT_SWAPS" "$PREFLIGHT_ZRAM") == "$APT_PLAN_INVENTORY" ]] || return 1
  sudo env "APT_CONFIG=$APT_PLAN_CONFIG" DEBIAN_FRONTEND=noninteractive apt-get --yes --no-install-recommends --no-remove --no-upgrade install "${APT_PLAN_MISSING[@]}" || result=$?
  apt_result=$result
  if ! preflight_install_inventory audit; then
    printf 'Error: post-APT inventory is indeterminate; see the earlier audit.\n' >&2
    PREFLIGHT_SERVICES+=$'\ninventory_status=unknown'
    result=1
  fi
  _apt_audit "$run" "$module" after "$apt_result" || return 1
  if [[ $PREFLIGHT_PACKAGES_STATE != known ]]; then
    APT_PLAN_TOKEN=''
    return 1
  fi
  for package in "${APT_PLAN_MISSING[@]}"; do
    installed=false
    if _apt_installed "$package"; then installed=true; fi
    python3 "$_PACKAGES_LIB/manifest.py" append "$run" \
      "{\"event\":\"package\",\"module\":\"$module\",\"package\":\"$package\",\"before_installed\":false,\"applied_installed\":$installed}" || return 1
    [[ $installed == true ]] || result=1
  done
  APT_PLAN_TOKEN=''
  if [[ $before_inventory != "$PREFLIGHT_PACKAGES" || $result != 0 ]]; then
    printf 'APT audit: package versions and service states before/after were recorded; review any service activation by package scripts.\n'
  fi
  return "$result"
}
