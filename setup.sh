#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/preflight.sh"
source "$SCRIPT_DIR/lib/packages.sh"
source "$SCRIPT_DIR/lib/memory.sh"
source "$SCRIPT_DIR/lib/gradle.sh"
source "$SCRIPT_DIR/lib/docker.sh"
source "$SCRIPT_DIR/lib/mise.sh"
source "$SCRIPT_DIR/lib/install-wrappers.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/rollback.sh"

usage() {
  cat <<'EOF'
Usage: setup.sh [--check | --dry-run] [options]
--only LIST             Select only comma-separated modules
--skip LIST             Skip comma-separated modules
--zram                  Select zram
--docker                Select Docker
--earlyoom              Select earlyoom (currently unavailable)
--gradle-global         Select global Gradle properties
--swappiness 0..200     Select vm.swappiness configuration
--skip-mise             Skip mise
--no-docker             Alias for --skip docker
--no-earlyoom           Alias for --skip earlyoom
--yes                   Confirm only modules selected and previewed
--check                 Run read-only host and conflict checks
--dry-run               Preview selected operations without changing the host
EOF
}

valid_module() {
  case "$1" in
  baseline | kvm | mise | wrappers | zram | docker | earlyoom | gradle-global | swappiness) return 0 ;;
  *)
    error "Unknown module: $1"
    return 2
    ;;
  esac
}

add_modules() {
  local kind=$1 list=$2 module
  local -a modules
  IFS=, read -r -a modules <<<"$list"
  [[ -n $list && $list != ,* && $list != *, && $list != *,,* ]] || {
    error 'Invalid module list.'
    return 2
  }
  for module in "${modules[@]}"; do
    valid_module "$module" || return 2
    if [[ $kind == only ]]; then only[$module]=1; else skip[$module]=1; fi
  done
}

setup_subset() {
  local allowed=" $1 " requested=$2 package
  for package in $requested; do
    [[ $allowed == *" $package "* ]] || return 1
  done
}

setup_action_subset() {
  local unexpected
  unexpected=$(comm -23 \
    <(printf '%s\n' "$2" | sed '/^$/d' | LC_ALL=C sort -u) \
    <(printf '%s\n' "$1" | sed '/^$/d' | LC_ALL=C sort -u))
  [[ -z $unexpected ]]
}

apt_preview_dependencies() {
  awk '$1 == "Inst" {sub(/^Inst[[:space:]]+/, ""); print}' <<<"${APT_PLAN_TRANSACTION:-}" | LC_ALL=C sort -u
}

declare -A only=() skip=() selected=() plan_tokens=() plan_missing=() plan_deps=()
declare -A plan_actions=() plan_providers=() plan_package_sets=()
mode=preview
yes=no
swappiness=
while (($#)); do
  case "$1" in
  --help | -h)
    usage
    exit 0
    ;;
  --check | --dry-run)
    [[ $mode == preview ]] || {
      error '--check and --dry-run are mutually exclusive.'
      exit 2
    }
    mode=${1#--}
    ;;
  --only | --skip)
    (($# >= 2)) && [[ -n $2 && $2 != --* ]] || {
      error "$1 requires a comma-separated list."
      exit 2
    }
    add_modules "${1#--}" "$2" || exit 2
    shift
    ;;
  --zram | --docker | --earlyoom | --gradle-global) selected[${1#--}]=1 ;;
  --swappiness)
    (($# >= 2)) && [[ $2 =~ ^(0|[1-9][0-9]{0,2})$ ]] && ((10#$2 <= 200)) || {
      error '--swappiness requires an integer from 0 through 200.'
      exit 2
    }
    swappiness=$2
    selected[swappiness]=1
    shift
    ;;
  --skip-mise) skip[mise]=1 ;;
  --no-docker) skip[docker]=1 ;;
  --no-earlyoom) skip[earlyoom]=1 ;;
  --yes) yes=yes ;;
  *)
    error "Unknown option: $1"
    usage >&2
    exit 2
    ;;
  esac
  shift
done

for module in "${!selected[@]}"; do
  if [[ -v skip[$module] ]]; then
    error "Module was both selected and skipped: $module"
    exit 2
  fi
done
for module in "${!only[@]}"; do
  if [[ -v skip[$module] ]]; then
    error "Module was both selected and skipped: $module"
    exit 2
  fi
done

if ((${#only[@]})); then
  for module in "${!only[@]}"; do selected[$module]=1; done
else
  for module in baseline kvm mise wrappers; do selected[$module]=1; done
fi
for module in "${!skip[@]}"; do unset 'selected[$module]'; done

host_facts=$(preflight_host) || exit 1
require_normal_user || exit 1
printf '%s\n' "$host_facts"
preflight_conflicts || exit 1
if [[ $mode == check ]]; then
  printf 'Read-only checks passed.\n'
  exit 0
fi

# A complete package and service inventory must be known before any plan can
# authorize an APT transaction or service change.
preflight_install_inventory || {
  error 'Package, swap, or service inventory is unknown; setup stopped before changes.'
  exit 1
}

module_order=(baseline kvm mise wrappers zram docker gradle-global swappiness earlyoom)
conflict_order=(baseline kvm mise wrappers zram swappiness gradle-global earlyoom docker)
for module in "${conflict_order[@]}"; do
  [[ -v selected[$module] ]] || continue
  case "$module" in
  baseline | kvm)
    mapfile -t module_packages < <(package_selection "$module") || exit 1
    _apt_barrier "$module" "${module_packages[@]}" || exit 1
    ;;
  mise) mise_plan >/dev/null || exit 1 ;;
  wrappers) : ;;
  zram) memory_plan --zram >/dev/null || exit 1 ;;
  swappiness) memory_plan --swappiness "$swappiness" >/dev/null || exit 1 ;;
  gradle-global) gradle_plan --global >/dev/null || exit 1 ;;
  earlyoom) memory_plan --earlyoom >/dev/null || exit 1 ;;
  docker)
    docker_plan >/dev/null || exit 1
    [[ $DOCKER_PLAN_ACTION != manual ]] || {
      error 'Docker service exists without a recognized package provider; manual review required before any module can be applied.'
      exit 1
    }
    ;;
  esac
done

for module in "${module_order[@]}"; do
  [[ -v selected[$module] ]] || continue
  printf 'module=%s\n' "$module"
  case "$module" in
  baseline | kvm)
    mapfile -t module_packages < <(package_selection "$module") || exit 1
    apt_plan "$module" "${module_packages[@]}" || exit 1
    plan_tokens[$module]=$APT_PLAN_TOKEN
    plan_missing[$module]="${APT_PLAN_MISSING[*]}"
    plan_deps[$module]=$(apt_preview_dependencies)
    printf 'command=sudo apt-get install [simulated %s package set]\n' "$module"
    ;;
  zram)
    mapfile -t module_packages < <(package_selection zram) || exit 1
    apt_plan zram "${module_packages[@]}" || exit 1
    plan_missing[zram]="${APT_PLAN_MISSING[*]}"
    plan_deps[zram]=$(apt_preview_dependencies)
    printf 'command=sudo apt-get install [simulated zram package set]\n'
    memory_plan --zram || exit 1
    plan_tokens[zram]=$MEMORY_PLAN_TOKEN
    printf 'command=sudo apt-get install zram-tools after simulation\n'
    ;;
  mise)
    mise_plan || exit 1
    if ! command -v minisign >/dev/null 2>&1 && ! _mise_find_existing; then
      apt_plan mise minisign || exit 1
      plan_tokens[mise]=$APT_PLAN_TOKEN
      plan_missing[mise]="${APT_PLAN_MISSING[*]}"
      plan_deps[mise]=$(apt_preview_dependencies)
    fi
    printf 'file=%s/.local/bin/mise\n' "$HOME"
    ;;
  wrappers)
    printf 'destination=%s/.local/bin and owned shell PATH block\n' "$HOME"
    ;;
  docker)
    docker_plan || exit 1
    plan_tokens[docker]=$DOCKER_PLAN_TOKEN
    plan_actions[docker]=$DOCKER_PLAN_ACTION
    plan_providers[docker]=$DOCKER_PLAN_PROVIDER
    plan_package_sets[docker]="${DOCKER_PLAN_PACKAGES[*]}"
    if [[ $DOCKER_PLAN_ACTION == install ]]; then
      plan_deps[docker]=$(apt_preview_dependencies)
      printf 'command=sudo apt-get install [simulated Docker package set]\n'
    else
      plan_deps[docker]=''
    fi
    ;;
  earlyoom)
    memory_plan --earlyoom || exit 1
    plan_tokens[earlyoom]=$MEMORY_PLAN_TOKEN
    ;;
  gradle-global)
    gradle_plan --global || exit 1
    plan_tokens[gradle - global]=$GRADLE_PLAN_TOKEN
    printf 'file=%s/gradle.properties\n' "${GRADLE_USER_HOME:-$HOME/.gradle}"
    ;;
  swappiness)
    memory_plan --swappiness "$swappiness" || exit 1
    plan_tokens[swappiness]=$MEMORY_PLAN_TOKEN
    ;;
  esac
done

if [[ $mode == dry-run || $yes != yes ]]; then
  printf 'Preview complete. No host changes were made. Re-run with --yes to apply these selected modules.\n'
  exit 0
fi

require_normal_user || exit 1
RUN_ID=''
ACTIVE_MODULE=setup
ACTIVE_PHASE=preflight
FAILURE_RECORDED=no

fail_run() {
  local status=${1:-1}
  ((status > 0 && status <= 255)) || status=1
  if [[ -n $RUN_ID && $FAILURE_RECORDED != yes ]]; then
    record_failure "$RUN_ID" "$ACTIVE_MODULE" "$ACTIVE_PHASE" "$status" ||
      error 'Could not append the failure record; preserve the run directory for manual recovery.'
    FAILURE_RECORDED=yes
    rollback_owned_preview "$RUN_ID" >&2 || error 'Owned rollback preview is unavailable; inspect the run manifest manually.'
    manual_recovery_notice "$RUN_ID" "$SCRIPT_DIR/bin/dev-rollback"
  fi
  return "$status"
}

handle_signal() {
  local status=$1
  trap - INT TERM HUP
  ACTIVE_PHASE=apply
  fail_run "$status" || true
  exit "$status"
}
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM
trap 'handle_signal 129' HUP

RUN_ID=$(begin_run) || {
  error 'Could not create a private setup journal.'
  exit 1
}
printf 'run_id=%s\n' "$RUN_ID"
for disk_path in / "$HOME" /var/cache/apt/archives; do
  [[ -d $disk_path ]] || disk_path=/var
  free_kb=$(df -Pk -- "$disk_path" | awk 'NR == 2 {print $4}') || free_kb=unknown
  if [[ ! $free_kb =~ ^[0-9]+$ ]] || ((free_kb < 1048576)); then
    ACTIVE_MODULE=setup
    ACTIVE_PHASE=preflight
    fail_run 1 || true
    error "At least 1 GiB of free space is required on $disk_path before installation; no module was applied."
    exit 1
  fi
done

if [[ -v selected[earlyoom] ]]; then
  ACTIVE_MODULE=earlyoom
  ACTIVE_PHASE=apply
  error 'earlyoom remains unavailable; no selected module was applied.'
  fail_run 1 || true
  exit 1
fi

apply_module() {
  local module=$1 token current_missing
  local -a module_packages
  case "$module" in
  baseline | kvm)
    mapfile -t module_packages < <(package_selection "$module") || return 1
    apt_plan "$module" "${module_packages[@]}" || return 1
    current_missing="${APT_PLAN_MISSING[*]}"
    current_deps=$(apt_preview_dependencies)
    setup_subset "${plan_missing[$module]}" "$current_missing" &&
      setup_action_subset "${plan_deps[$module]}" "$current_deps" || {
      error "The $module package or dependency set grew after preview; re-run setup and review it."
      return 1
    }
    token=$APT_PLAN_TOKEN
    apt_apply "$RUN_ID" "$module" --confirmed "$token" "${module_packages[@]}"
    ;;
  mise)
    if ! command -v minisign >/dev/null 2>&1 && ! _mise_find_existing; then
      apt_plan mise minisign || return 1
      current_missing="${APT_PLAN_MISSING[*]}"
      current_deps=$(apt_preview_dependencies)
      setup_subset "${plan_missing[mise]}" "$current_missing" &&
        setup_action_subset "${plan_deps[mise]}" "$current_deps" || {
        error 'The minisign package or dependency set grew after preview; re-run setup and review it.'
        return 1
      }
    fi
    mise_apply "$RUN_ID"
    ;;
  wrappers) install_wrappers "$RUN_ID" ;;
  zram)
    mapfile -t module_packages < <(package_selection zram) || return 1
    apt_plan zram "${module_packages[@]}" || return 1
    current_missing="${APT_PLAN_MISSING[*]}"
    current_deps=$(apt_preview_dependencies)
    setup_subset "${plan_missing[zram]}" "$current_missing" &&
      setup_action_subset "${plan_deps[zram]}" "$current_deps" || {
      error 'The zram package or dependency set grew after preview; re-run setup and review it.'
      return 1
    }
    memory_plan --zram || return 1
    memory_apply "$RUN_ID" zram "$MEMORY_PLAN_TOKEN"
    ;;
  docker)
    docker_plan >/dev/null || return 1
    [[ $DOCKER_PLAN_ACTION == "${plan_actions[docker]}" &&
      $DOCKER_PLAN_PROVIDER == "${plan_providers[docker]}" &&
      "${DOCKER_PLAN_PACKAGES[*]}" == "${plan_package_sets[docker]}" ]] || {
      error 'Docker provider or package selection changed after preview; re-run setup and review it.'
      return 1
    }
    setup_subset "${plan_package_sets[docker]}" "${DOCKER_PLAN_PACKAGES[*]}" || {
      error 'The Docker package or dependency set grew after preview; re-run setup and review it.'
      return 1
    }
    if [[ ${plan_actions[docker]} == install ]]; then
      current_deps=$(apt_preview_dependencies)
      setup_action_subset "${plan_deps[docker]}" "$current_deps" || {
        error 'The Docker package or dependency set grew after preview; re-run setup and review it.'
        return 1
      }
    fi
    if [[ ${plan_actions[docker]} == preserve ]]; then
      printf 'Docker already exists; existing provider and service preserved.\n'
      return 0
    fi
    docker_apply "$RUN_ID" --docker --confirmed "$DOCKER_PLAN_TOKEN"
    ;;
  earlyoom)
    memory_plan --earlyoom || return 1
    [[ ${MEMORY_PLAN_SUPPORTED:-yes} == yes ]] || {
      error 'earlyoom remains unavailable until constrained-build kill priority can be guaranteed.'
      return 1
    }
    memory_apply "$RUN_ID" earlyoom "$MEMORY_PLAN_TOKEN"
    ;;
  gradle-global)
    gradle_plan --global >/dev/null || return 1
    [[ $GRADLE_PLAN_TOKEN == "${plan_tokens[gradle - global]}" ]] || {
      error 'Global Gradle state changed after preview; re-run setup and review it.'
      return 1
    }
    gradle_global_apply "$RUN_ID" --gradle-global --confirmed "$GRADLE_PLAN_TOKEN"
    ;;
  swappiness)
    memory_plan --swappiness "$swappiness" || return 1
    memory_apply "$RUN_ID" swappiness "$MEMORY_PLAN_TOKEN"
    ;;
  esac
}

verify_module() {
  local module=$1 package
  case "$module" in
  baseline | kvm)
    while IFS= read -r package; do
      [[ -n $package ]] || continue
      _apt_installed "$package" || {
        error "Package verification failed: $package"
        return 1
      }
    done < <(package_selection "$module")
    ;;
  mise)
    _mise_find_existing || {
      error 'mise executable verification failed.'
      return 1
    }
    "$MISE_EXEC_PATH" --version >/dev/null || return 1
    ;;
  wrappers)
    for package in dev-run dev-build dev-emulator dev-doctor dev-profile dev-rollback; do
      [[ -x $HOME/.local/bin/$package ]] || return 1
    done
    [[ $(grep -Fc '# >>> vaio-fe16 user wrappers >>>' "$HOME/.bashrc") == 1 ]] || return 1
    ;;
  zram)
    [[ $(systemctl is-active zramswap.service 2>/dev/null) == active ]] || return 1
    [[ $(swapon --show=NAME --noheadings 2>/dev/null) == *zram* ]] || return 1
    ;;
  docker)
    [[ ${plan_actions[docker]} == preserve ]] ||
      [[ $(systemctl is-active docker.service 2>/dev/null) == active ]] || return 1
    ;;
  earlyoom) return 1 ;;
  gradle-global)
    [[ -f ${GRADLE_USER_HOME:-$HOME/.gradle}/gradle.properties ]] || return 1
    grep -Fq '# >>> vaio-fe16 gradle >>>' "${GRADLE_USER_HOME:-$HOME/.gradle}/gradle.properties" || return 1
    ;;
  swappiness) [[ $(sysctl -n vm.swappiness) == "$swappiness" ]] || return 1 ;;
  esac
}

for module in "${module_order[@]}"; do
  [[ -v selected[$module] ]] || continue
  ACTIVE_MODULE=$module
  ACTIVE_PHASE=apply
  if apply_module "$module"; then
    :
  else
    status=$?
    ((status != 0)) || status=1
    fail_run "$status" || true
    exit "$status"
  fi
  ACTIVE_PHASE=verify
  if verify_module "$module"; then
    :
  else
    status=$?
    ((status != 0)) || status=1
    fail_run "$status" || true
    exit "$status"
  fi
  printf 'verified=%s\n' "$module"
done

ACTIVE_MODULE=setup
ACTIVE_PHASE=verify
python3 "$SCRIPT_DIR/lib/manifest.py" verify "$RUN_ID" || {
  fail_run 1 || true
  exit 1
}
"$SCRIPT_DIR/bin/dev-doctor" || {
  fail_run 1 || true
  exit 1
}
printf 'Setup completed. run_id=%s\n' "$RUN_ID"
