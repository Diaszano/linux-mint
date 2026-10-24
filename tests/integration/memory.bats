#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  WORK="$BATS_TEST_TMPDIR/work"
  mkdir -p "$WORK"
}

@test "default memory plan is read-only and preserves active kernel policy" {
  swaps=$(cat /proc/swaps)
  zram=$(zramctl --noheadings --raw --output NAME,DISKSIZE 2>/dev/null || true)
  swappiness=$(sysctl -n vm.swappiness)
  page_cluster=$(sysctl -n vm.page-cluster)
  run bash -c 'set -euo pipefail; source "$1/lib/preflight.sh"; source "$1/lib/memory.sh"; memory_plan' _ "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *preserv* ]]
  [ "$(cat /proc/swaps)" = "$swaps" ]
  [ "$(zramctl --noheadings --raw --output NAME,DISKSIZE 2>/dev/null || true)" = "$zram" ]
  [ "$(sysctl -n vm.swappiness)" = "$swappiness" ]
  [ "$(sysctl -n vm.page-cluster)" = "$page_cluster" ]
}

@test "unselected plan does not install packages or alter systemd policy" {
  before=$(systemctl list-unit-files --no-legend --no-pager | sha256sum)
  run bash -c 'set -euo pipefail; source "$1/lib/preflight.sh"; source "$1/lib/memory.sh"; memory_plan' _ "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(systemctl list-unit-files --no-legend --no-pager | sha256sum)" = "$before" ]
}
