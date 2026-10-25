#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH" DOCTOR_MUTATIONS="$BATS_TEST_TMPDIR/mutations"
  mkdir -p "$HOME" "$XDG_STATE_HOME" "$BATS_TEST_TMPDIR/bin"
  for tool in sudo apt-get; do
    cat >"$BATS_TEST_TMPDIR/bin/$tool" <<'EOF'
#!/bin/sh
printf '%s %s\n' "${0##*/}" "$*" >>"$DOCTOR_MUTATIONS"
exit 99
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/$tool"
  done
}

@test "JSON doctor has stable component keys and invokes no mutators" {
  export DOCTOR_SENTINEL_SECRET='never serialize this'
  run "$ROOT/bin/dev-doctor" --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -c '
import json, sys
data=json.load(sys.stdin)
expected={"host", "swap", "zram", "kvm", "mesa", "thermal_power", "cgroup_controllers", "gradle", "mise", "sdk", "docker", "run_manifest"}
assert set(data) == expected, sorted(data)
assert "never serialize this" not in json.dumps(data)
for component in data.values():
    assert isinstance(component, dict) and "status" in component
'
  [ ! -e "$DOCTOR_MUTATIONS" ]
  [ -z "$(find "$HOME" "$XDG_STATE_HOME" -mindepth 1 -print -quit)" ]
}

@test "unavailable KVM is not reported as PASS and includes manual guidance" {
  cat >"$BATS_TEST_TMPDIR/bin/kvm-ok" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/kvm-ok"
  run "$ROOT/bin/dev-doctor" --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -c '
import json, sys
kvm=json.load(sys.stdin)["kvm"]
assert kvm["status"] in ("FAIL", "NOT INSTALLED", "WARN")
assert kvm["status"] != "PASS"
assert kvm.get("manual")
'
  [ ! -e "$DOCTOR_MUTATIONS" ]
}

@test "doctor reports VM sysctls without modifying them" {
  before_swappiness=$(cat /proc/sys/vm/swappiness)
  before_page_cluster=$(cat /proc/sys/vm/page-cluster)
  run "$ROOT/bin/dev-doctor"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$before_swappiness"* ]]
  [[ "$output" == *"$before_page_cluster"* ]]
  [ "$(cat /proc/sys/vm/swappiness)" = "$before_swappiness" ]
  [ "$(cat /proc/sys/vm/page-cluster)" = "$before_page_cluster" ]
  [ ! -e "$DOCTOR_MUTATIONS" ]
}

@test "empty or failed thermal probes are not reported as PASS" {
  cat >"$BATS_TEST_TMPDIR/bin/sensors" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$BATS_TEST_TMPDIR/bin/powerprofilesctl" <<'EOF'
#!/bin/sh
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/sensors" "$BATS_TEST_TMPDIR/bin/powerprofilesctl"
  run "$ROOT/bin/dev-doctor" --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -c '
import json, sys
thermal=json.load(sys.stdin)["thermal_power"]
assert thermal["temperature_status"] != "PASS"
assert thermal["power_profile_status"] != "PASS"
'
}

@test "installed zram manager without an active device is reported as a warning" {
  cat >"$BATS_TEST_TMPDIR/bin/zramctl" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$BATS_TEST_TMPDIR/bin/dpkg-query" <<'EOF'
#!/bin/sh
case "$*" in
  *zram-tools*) printf 'installed\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/zramctl" "$BATS_TEST_TMPDIR/bin/dpkg-query"
  run "$ROOT/bin/dev-doctor" --json
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | python3 -c '
import json, sys
zram=json.load(sys.stdin)["zram"]
assert zram["status"] == "WARN"
assert zram["manager_packages"] == "zram-tools"
'
}

@test "doctor accepts only no arguments or --json" {
  run "$ROOT/bin/dev-doctor" --fix
  [ "$status" -eq 2 ]
  [ ! -e "$DOCTOR_MUTATIONS" ]
}
