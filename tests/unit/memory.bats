#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export ROOT HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$HOME"
}

plan() {
  bash -c '
    set -euo pipefail
    source "$ROOT/lib/memory.sh"
    preflight_install_inventory() {
      PREFLIGHT_PACKAGES=$'"'"'bash\tinstall ok installed\t5.2'"'"'
      PREFLIGHT_PACKAGES_STATE=known
      PREFLIGHT_SERVICES=${EVIDENCE:-}
      PREFLIGHT_CONFLICT_SERVICES=$PREFLIGHT_SERVICES
      PREFLIGHT_SWAPS=${SWAPS:-}
      PREFLIGHT_ZRAM=${ZRAM:-}
      [[ ${UNKNOWN:-no} == no ]]
    }
    sysctl() { printf "60\n"; }
    modprobe() { return 0; }
    _memory_package_contract() { :; }
    apt_plan() { APT_PLAN_TOKEN=approved; printf "apt-plan=%s\n" "$*"; }
    memory_plan "$@"
  ' bash "$@"
}

@test "default preserves swaps managers and effective VM policy without APT" {
  export EVIDENCE='system:earlyoom.service zram' SWAPS='/dev/zram0 partition 1G 200'
  run plan
  [ "$status" = 0 ]
  [[ "$output" == *'preserve'* && "$output" != *apt-plan* ]]
  [ ! -d "$XDG_STATE_HOME" ]
}

@test "explicit zram previews LZ4 half RAM priority and missing disk swap" {
  run plan --zram
  [ "$status" = 0 ]
  [[ "$output" == *'ALGO=lz4'* && "$output" == *'PERCENT=50'* && "$output" == *'PRIORITY=100'* ]]
  [[ "$output" == *'disk swap'* && "$output" == *'zramswap.service'* ]]
}

@test "unknown inventory refuses memory changes before APT" {
  export UNKNOWN=yes
  run plan --zram
  [ "$status" != 0 ]
  [[ "$output" != *apt-plan* ]]
}

@test "existing managers or custom units refuse zram before APT" {
  for evidence in zram-config zramswap systemd-zram-generator 'personal.service ManagerEvidence= zram'; do
    export EVIDENCE=$evidence
    run plan --zram
    [ "$status" != 0 ]
    [[ "$output" != *apt-plan* ]]
  done
}

@test "disk priority at or above proposed zram priority is preserved and blocks" {
  export SWAPS='/swapfile file 2G 100'
  run plan --zram
  [ "$status" != 0 ]
  [[ "$output" != *apt-plan* ]]
}

@test "existing OOM protection refuses earlyoom even with unrelated unit name" {
  for evidence in earlyoom systemd-oomd 'user:personal.service ManagerEvidence= oom-manager'; do
    export EVIDENCE=$evidence
    run plan --earlyoom
    [ "$status" != 0 ]
    [[ "$output" != *apt-plan* ]]
  done
}

@test "earlyoom previews an explicit conservative kill policy" {
  run plan --earlyoom
  [ "$status" = 0 ]
  [[ "$output" == *'EARLYOOM_ARGS="-m 10,5 -s 10,5"'* ]]
  [[ "$output" == *'largest process'* && "$output" == *'terminate applications'* ]]
}

@test "sysctl conflict parser finds active vm.swappiness assignments only" {
  file="$BATS_TEST_TMPDIR/sysctl.conf"
  printf '# vm.swappiness=20\nnet.ipv4.ip_forward=1\n vm.swappiness = 40\n' >"$file"
  run bash -c 'source "$ROOT/lib/memory.sh"; _memory_sysctl_file_conflict "$1"' _ "$file"
  [ "$status" = 0 ]
  [[ "$output" == *"$file"* ]]
  printf '# vm.swappiness=20\nnet.ipv4.ip_forward=1\n' >"$file"
  run bash -c 'source "$ROOT/lib/memory.sh"; _memory_sysctl_file_conflict "$1"' _ "$file"
  [ "$status" = 1 ]
}

@test "swappiness planning refuses competing sysctl policy before mutation" {
  export ZRAM='/dev/zram0 algo=lz4 disksize=50%'
  export SWAPS='/dev/zram0 partition 4G 100'
  run bash -c '
    source "$ROOT/lib/memory.sh"
    preflight_install_inventory() {
      PREFLIGHT_PACKAGES=$'"'"'bash\tinstall ok installed\t5.2'"'"'
      PREFLIGHT_PACKAGES_STATE=known PREFLIGHT_SERVICES=known PREFLIGHT_CONFLICT_SERVICES=known
      PREFLIGHT_SWAPS=$SWAPS PREFLIGHT_ZRAM=$ZRAM
    }
    _memory_sysctl_conflict() { printf "/etc/sysctl.d/50-admin.conf\n"; return 0; }
    apt_plan() { echo SHOULD_NOT_PLAN; }
    memory_plan --swappiness 100
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *'vm.swappiness'* && "$output" != *SHOULD_NOT_PLAN* ]]
}

@test "swappiness apply rechecks competing policy before file writes or sysctl" {
  run bash -c '
    source "$ROOT/lib/memory.sh"
    preflight_install_inventory() {
      PREFLIGHT_PACKAGES=$'"'"'bash\tinstall ok installed\t5.2'"'"'
      PREFLIGHT_PACKAGES_STATE=known PREFLIGHT_SERVICES=known PREFLIGHT_CONFLICT_SERVICES=known
      PREFLIGHT_SWAPS=$'"'"'/dev/zram0 partition 4G 100'"'"'
      PREFLIGHT_ZRAM="/dev/zram0 algo=lz4 disksize=50%"
    }
    _memory_sysctl_conflict() { [[ ${COLLISION:-no} == yes ]] && { echo /etc/sysctl.d/50-admin.conf; return 0; }; return 1; }
    sysctl() { echo SYSCTL_SHOULD_NOT_RUN; }
    memory_plan --swappiness 100 >/dev/null
    token=$MEMORY_PLAN_TOKEN
    COLLISION=yes memory_apply fake-run swappiness "$token"
  '
  [ "$status" -ne 0 ]
  [[ "$output" == *'vm.swappiness'* && "$output" != *SYSCTL_SHOULD_NOT_RUN* ]]
}

@test "swappiness cannot be selected without verified active compatible zram" {
  run plan --swappiness 100
  [ "$status" != 0 ]
  [[ "$output" != *apt-plan* ]]
}

@test "unreviewed package behavior fails with manual guidance before APT" {
  run bash -c 'source "$ROOT/lib/memory.sh"; apt-cache() { printf "Candidate: 999\n"; }; _memory_package_contract zram'
  [ "$status" != 0 ]
  [[ "$output" == *manual* ]]
}

@test "privileged helper rejects a forbidden target before touching it" {
  run python3 "$ROOT/lib/memory_file.py" replace /etc/fstab missing missing
  [ "$status" != 0 ]
  [[ "$output" == *'target not allowed'* ]]
}

@test "privileged helper refuses a memory target checksum conflict" {
  run python3 "$ROOT/lib/memory_file.py" replace /etc/default/zramswap wrong missing
  [ "$status" -ne 0 ]
  [[ "$output" == *'checksum or inode conflict'* ]]
}

@test "memory apply requires the exact plan token" {
  run bash -c 'source "$ROOT/lib/memory.sh"; MEMORY_PLAN_MODULE=zram; MEMORY_PLAN_TOKEN=approved; memory_apply run-id zram wrong'
  [ "$status" -ne 0 ]
  [[ "$output" == *'token da prévia confirmada'* ]]
}

@test "rollback refuses to stop zram after activation may have begun" {
  run python3 "$ROOT/lib/manifest.py" init
  [ "$status" -eq 0 ]
  run_id=$output
  run python3 "$ROOT/lib/memory_file.py" audit "$run_id" zram activating '{"unit":"zramswap.service"}'
  [ "$status" -eq 0 ]
  run bash -c 'source "$ROOT/lib/rollback.sh"; rollback_apply "$1"' _ "$run_id"
  [ "$status" -ne 0 ]
  [[ "$output" == *'Manual recovery required: zram is active'* ]]
}
