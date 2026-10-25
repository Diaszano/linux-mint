#!/usr/bin/env bats

setup() {
  ROOT=$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)
  export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export PREFLIGHT_FIXTURES="$BATS_TEST_TMPDIR" PROBE_LOG="$BATS_TEST_TMPDIR/probes"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  chmod 700 "$(dirname "$BATS_TEST_TMPDIR")" "$BATS_TEST_TMPDIR" "$HOME"
  : >"$HOME/.bashrc"
  : >"$PROBE_LOG"
  printf 'ID=linuxmint\nVERSION_ID="22.3"\nUBUNTU_CODENAME=noble\n' >"$BATS_TEST_TMPDIR/os-release"
  printf 'MemTotal: 24576000 kB\n' >"$BATS_TEST_TMPDIR/meminfo"
  cat >"$BATS_TEST_TMPDIR/bin/cat" <<'EOF'
#!/bin/sh
case "$1" in
  /etc/os-release) exec /usr/bin/cat "$PREFLIGHT_FIXTURES/os-release" ;;
  /proc/meminfo) exec /usr/bin/cat "$PREFLIGHT_FIXTURES/meminfo" ;;
esac
exec /usr/bin/cat "$@"
EOF
  cat >"$BATS_TEST_TMPDIR/bin/id" <<'EOF'
#!/bin/sh
if [ "${1:-}" = -u ]; then echo 1000; else exec /usr/bin/id "$@"; fi
EOF
  cat >"$BATS_TEST_TMPDIR/bin/uname" <<'EOF'
#!/bin/sh
echo x86_64
EOF
  cat >"$BATS_TEST_TMPDIR/bin/nproc" <<'EOF'
#!/bin/sh
echo 16
EOF
  cat >"$BATS_TEST_TMPDIR/bin/df" <<'EOF'
#!/bin/sh
for arg do path=$arg; done
case "${path:-}" in
  /) low=${ROOT_LOW_DISK:-${LOW_DISK:-no}} ;;
  /var/cache/apt/archives) low=${APT_DISK_LOW:-${LOW_DISK:-no}} ;;
  *) low=${HOME_LOW_DISK:-${LOW_DISK:-no}} ;;
esac
if [ "$low" = yes ]; then
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda2 1000000 999999 1 100%% /\n'
else
  printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda2 100000000 40000000 60000000 40%% /\n'
fi
EOF
  cat >"$BATS_TEST_TMPDIR/bin/findmnt" <<'EOF'
#!/bin/sh
echo /dev/sda2
EOF
  cat >"$BATS_TEST_TMPDIR/bin/lsblk" <<'EOF'
#!/bin/sh
echo 0
EOF
  cat >"$BATS_TEST_TMPDIR/bin/glxinfo" <<'EOF'
#!/bin/sh
echo 'OpenGL renderer string: AMD Radeon Graphics'
EOF
  cat >"$BATS_TEST_TMPDIR/bin/swapon" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$BATS_TEST_TMPDIR/bin/zramctl" <<'EOF'
#!/bin/sh
exit 0
EOF
  cat >"$BATS_TEST_TMPDIR/bin/dpkg-query" <<'EOF'
#!/bin/sh
last_arg=
for arg do last_arg=$arg; done
if [ -f "$APT_INSTALLED_FILE" ] && grep -Fxq -- "$last_arg" "$APT_INSTALLED_FILE"; then
  echo 'install ok installed'
  exit 0
fi
case "$*" in
  *binary:Package*)
    printf 'bash\tinstall ok installed\t5.2\n'
if [ -f "$APT_INSTALLED_FILE" ]; then
  while IFS= read -r package; do printf '%s\tinstall ok installed\t1.0\n' "$package"; done <"$APT_INSTALLED_FILE"
fi
    if [ "${ZRAM_CONFLICT:-no}" = yes ]; then printf 'zram-tools\tinstall ok installed\t0.3.3\n'; fi
    if [ "${OOM_CONFLICT:-no}" = yes ]; then printf 'earlyoom\tinstall ok installed\t1.7\n'; fi
    if [ "${DOCKER_CONFLICT:-no}" = yes ]; then
      printf 'docker.io\tinstall ok installed\t26.1\n'
      printf 'docker-ce\tinstall ok installed\t27.0\n'
    fi
if [ "${DOCKER_EXISTING:-}" = distro ]; then printf 'docker.io\tinstall ok installed\t26.1\n'; fi
    ;;
  *zram-tools*)
    if [ "${ZRAM_CONFLICT:-no}" = yes ]; then echo 'install ok installed'; else echo 'unknown ok not-installed'; fi
    ;;
  *earlyoom*)
    if [ "${OOM_CONFLICT:-no}" = yes ]; then echo 'install ok installed'; else echo 'unknown ok not-installed'; fi
    ;;
  *docker.io*|*docker-ce*)
if [ "${DOCKER_CONFLICT:-no}" = yes ]; then echo 'install ok installed'; elif [ "${DOCKER_EXISTING:-}" = distro ]; then
    case "$*" in *docker.io*) echo 'install ok installed' ;; *) echo 'unknown ok not-installed' ;; esac
else echo 'unknown ok not-installed'; fi
    ;;
  *) echo 'unknown ok not-installed' ;;
esac
EOF
  cat >"$BATS_TEST_TMPDIR/bin/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >>"$PROBE_LOG"
case "$*" in
*is-active*docker.service*) [ "${DOCKER_EXISTING:-}" = distro ] && exit 0; exit 3 ;;
*is-active*) exit 3 ;;
*show*docker.service*)
  if [ "${DOCKER_MANUAL:-no}" = yes ]; then
    printf 'LoadState=loaded\nUnitFileState=disabled\nActiveState=inactive\n'
  elif [ "${DOCKER_EXISTING:-}" = distro ]; then
    printf 'LoadState=loaded\nUnitFileState=enabled\nActiveState=active\n'
  else
    printf 'LoadState=not-found\nUnitFileState=disabled\nActiveState=inactive\n'
  fi
  exit 0 ;;
*show*) printf 'LoadState=not-found\nUnitFileState=disabled\nActiveState=inactive\n'; exit 0 ;;
  *list-units*|*list-unit-files*) exit 0 ;;
  *) exit 0 ;;
esac
EOF
  cat >"$BATS_TEST_TMPDIR/bin/apt-get" <<'EOF'
#!/bin/sh
printf 'apt-get %s\n' "$*" >>"$PROBE_LOG"
case "$*" in
  *--simulate*)
    count=0
    [ ! -f "$APT_SIM_COUNT" ] || read -r count <"$APT_SIM_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" >"$APT_SIM_COUNT"
    printf 'Inst bash (5.2)\n' >>"$PROBE_LOG"
    echo 'Reading package lists... Done'
    echo 'Inst bash (5.2)'
    if [ "${APT_EXTRA_AFTER_PREVIEW:-no}" = yes ] && [ "$count" -ge 2 ]; then
      echo 'Inst curl (8.0)'
    fi
    exit 0
    ;;
  *install*)
    if [ "${APT_INTERRUPT:-no}" = yes ]; then kill -INT "$PPID"; exit 130; fi
    [ "${APT_FAIL:-no}" = yes ] && exit 100
    installed=no
    for arg do
      if [ "$arg" = install ]; then installed=yes; continue; fi
      if [ "$installed" = yes ]; then printf '%s\n' "$arg" >>"$APT_INSTALLED_FILE"; fi
    done
    exit 0
    ;;
  *) [ "${APT_FAIL:-no}" = yes ] && exit 100; exit 0 ;;
esac
EOF
  cat >"$BATS_TEST_TMPDIR/bin/sudo" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >>"$PROBE_LOG"
[ "${SUDO_DENY:-no}" = yes ] && exit 1
exec "$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/"*
  cat >"$BATS_TEST_TMPDIR/bin/minisign" <<'EOF'
#!/bin/sh
[ "${1:-}" = -V ] && { echo minisign 0.11; exit 0; }
exit 1
EOF
  cat >"$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/bin/sh
exit 7
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/minisign" "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export APT_SIM_COUNT="$BATS_TEST_TMPDIR/apt-sim-count"
  export APT_INSTALLED_FILE="$BATS_TEST_TMPDIR/apt-installed"
}

failure_run_id() {
  grep -oE 'run_id=[0-9]{20}-[0-9a-f]{16}' <<<"$output" | head -n 1 | cut -d= -f2
}

assert_failure_record() {
  local run_id=$1 module=$2 phase=$3 status=$4
  python3 - "$XDG_STATE_HOME/vaio-fe16-dev-setup/runs/$run_id/manifest.jsonl" "$module" "$phase" "$status" <<'PY'
import json, sys
events = [json.loads(line) for line in open(sys.argv[1], encoding='utf-8')]
assert events[-1] == {'event': 'failure', 'module': sys.argv[2], 'phase': sys.argv[3], 'exit_code': int(sys.argv[4])}
PY
}

@test "check and dry run never create a journal or run privileged operations" {
  run bash "$ROOT/setup.sh" --check
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_STATE_HOME/vaio-fe16-dev-setup" ]
  run bash "$ROOT/setup.sh" --dry-run --yes --only wrappers
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_STATE_HOME/vaio-fe16-dev-setup" ]
  ! grep -Eq 'apt-get|sudo|systemctl (enable|start|restart|mask)' "$PROBE_LOG"
}

@test "apply requires yes and installs only selected and previewed modules" {
  run bash "$ROOT/setup.sh" --only wrappers
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/bin/dev-run" ]
  run bash "$ROOT/setup.sh" --only wrappers --yes
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/dev-run" ]
  [ -x "$HOME/.local/bin/dev-build" ]
  [[ "$output" == *'run_id='* ]]
  run bash "$ROOT/setup.sh" --only wrappers --yes
  [ "$status" -eq 0 ]
  [ "$(grep -Fc '# >>> vaio-fe16 user wrappers >>>' "$HOME/.bashrc")" -eq 1 ]
  ! grep -Eq 'systemctl (enable|start|restart|mask)' "$PROBE_LOG"
}

@test "unknown flags fail with status two before probes or journal creation" {
  run bash "$ROOT/setup.sh" --not-a-real-option
  [ "$status" -eq 2 ]
  [ ! -s "$PROBE_LOG" ]
  [ ! -e "$XDG_STATE_HOME/vaio-fe16-dev-setup" ]
}

@test "root filesystem low space blocks after journaling and before module changes" {
  printf 'keep this content\n' >"$HOME/.bashrc"
  export ROOT_LOW_DISK=yes HOME_LOW_DISK=no
  run bash "$ROOT/setup.sh" --only wrappers --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'1 GiB'* ]]
  [[ "$output" == *'run_id='* ]]
  [ -d "$XDG_STATE_HOME/vaio-fe16-dev-setup/runs" ]
  ! grep -Eq 'apt-get .*--yes|sudo |systemctl .* (enable|start|restart|mask)' "$PROBE_LOG"
  ! grep -q 'sudo ' "$PROBE_LOG"
  [ ! -e "$HOME/.local/bin/dev-run" ]
  [ "$(cat "$HOME/.bashrc")" = 'keep this content' ]
}

@test "global Gradle requires separate explicit selection" {
  run bash "$ROOT/setup.sh" --yes --only wrappers
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.gradle/gradle.properties" ]
}

@test "global Gradle property collision is rejected before journal or writes" {
  export GRADLE_USER_HOME="$BATS_TEST_TMPDIR/custom-gradle"
  mkdir -p "$GRADLE_USER_HOME"
  printf 'org.gradle.jvmargs=-Xmx2g\n' >"$GRADLE_USER_HOME/gradle.properties"
  run bash "$ROOT/setup.sh" --only wrappers --gradle-global --yes
  [ "$status" -ne 0 ]
  [ ! -e "$XDG_STATE_HOME/vaio-fe16-dev-setup" ]
  [ "$(cat "$GRADLE_USER_HOME/gradle.properties")" = 'org.gradle.jvmargs=-Xmx2g' ]
  ! grep -Eq 'apt-get|^sudo |systemctl (enable|start|restart|mask)' "$PROBE_LOG"
}

@test "sudo denial records the failed module and preserves user files" {
  printf 'keep this content\n' >"$HOME/.bashrc"
  export SUDO_DENY=yes
  run bash "$ROOT/setup.sh" --only baseline,wrappers --yes
  [ "$status" -ne 0 ]
  run_id=$(failure_run_id)
  [ -n "$run_id" ]
  assert_failure_record "$run_id" baseline apply 1
  [ "$(cat "$HOME/.bashrc")" = 'keep this content' ]
  [ ! -e "$HOME/.local/bin/dev-run" ]
  ! grep -Eq 'systemctl (enable|start|restart|mask)' "$PROBE_LOG"
}

@test "a new APT dependency after preview fails before package installation" {
  printf 'keep this content\n' >"$HOME/.bashrc"
  export APT_EXTRA_AFTER_PREVIEW=yes
  run bash "$ROOT/setup.sh" --only baseline --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'package or dependency set grew after preview'* ]]
  run_id=$(failure_run_id)
  [ -n "$run_id" ]
  assert_failure_record "$run_id" baseline apply 1
  [ "$(cat "$HOME/.bashrc")" = 'keep this content' ]
  ! grep -Eq '^sudo |apt-get .*--yes' "$PROBE_LOG"
}

@test "an interrupted APT transaction is journaled with its run id" {
  printf 'keep this content\n' >"$HOME/.bashrc"
  export APT_INTERRUPT=yes
  run bash "$ROOT/setup.sh" --only baseline,wrappers --yes
  [ "$status" -ne 0 ]
  run_id=$(failure_run_id)
  [ -n "$run_id" ]
  assert_failure_record "$run_id" baseline apply 130
  [ "$(cat "$HOME/.bashrc")" = 'keep this content' ]
  [ ! -e "$HOME/.local/bin/dev-run" ]
}

@test "mise network failure records a failure after confirming the signed release preview" {
  printf 'keep this content\n' >"$HOME/.bashrc"
  run bash "$ROOT/setup.sh" --only mise --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'pinned=v2026.10.18'* ]]
  run_id=$(failure_run_id)
  [ -n "$run_id" ]
  assert_failure_record "$run_id" mise apply 1
  [ ! -e "$HOME/.local/bin/mise" ]
  [ "$(cat "$HOME/.bashrc")" = 'keep this content' ]
}

@test "zram conflicts stop before APT mutation and before a run journal" {
  export ZRAM_CONFLICT=yes
  run bash "$ROOT/setup.sh" --only zram --yes
  [ "$status" -ne 0 ]
  [ ! -e "$XDG_STATE_HOME/vaio-fe16-dev-setup" ]
  ! grep -Eq '^sudo |apt-get .*--yes' "$PROBE_LOG"
  ! grep -Eq 'systemctl (enable|start|restart|mask)' "$PROBE_LOG"
}

@test "existing OOM manager conflicts stop before any selected package operation" {
  export OOM_CONFLICT=yes
  run bash "$ROOT/setup.sh" --only earlyoom --yes
  [ "$status" -ne 0 ]
  [ ! -e "$XDG_STATE_HOME/vaio-fe16-dev-setup" ]
  ! grep -Eq 'apt-get|^sudo |systemctl (enable|start|restart|mask)' "$PROBE_LOG"
}

@test "conflicting Docker providers stop before any APT or service operation" {
  export DOCKER_CONFLICT=yes
  run bash "$ROOT/setup.sh" --only docker --yes
  [ "$status" -ne 0 ]
  [ ! -e "$XDG_STATE_HOME/vaio-fe16-dev-setup" ]
  ! grep -Eq 'apt-get|^sudo |systemctl (enable|start|restart|mask)' "$PROBE_LOG"
}

@test "earlyoom stays unavailable and fails closed with a run id" {
  run bash "$ROOT/setup.sh" --only earlyoom --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'earlyoom remains unavailable'* ]]
  run_id=$(failure_run_id)
  [ -n "$run_id" ]
  assert_failure_record "$run_id" earlyoom apply 1
  ! grep -Eq '^sudo |systemctl (enable|start|restart|mask)' "$PROBE_LOG"
}

@test "unsupported host is refused before journal or installation" {
  printf 'ID=ubuntu\nVERSION_ID=24.04\nUBUNTU_CODENAME=noble\n' >"$BATS_TEST_TMPDIR/os-release"
  run bash "$ROOT/setup.sh" --only wrappers --yes
  [ "$status" -ne 0 ]
  [ ! -e "$XDG_STATE_HOME/vaio-fe16-dev-setup" ]
  ! grep -Eq '^sudo |apt-get .*--yes|systemctl (enable|start|restart|mask)' "$PROBE_LOG"
}

@test "a prior APT plan does not invalidate preserved Docker" {
  export DOCKER_EXISTING=distro
  run bash "$ROOT/setup.sh" --only baseline --docker --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *'Docker already exists'* ]]
  grep -q '^apt-get --simulate .* install ' "$PROBE_LOG"
  grep -q '^Inst bash (5.2)$' "$PROBE_LOG"
  grep -q '^apt-get --yes .* install ' "$PROBE_LOG"
  ! grep -q 'apt-get .*docker.io' "$PROBE_LOG"
  ! grep -Eq 'systemctl .* (enable|start|restart) docker.service' "$PROBE_LOG"
}
@test "Docker manual action is rejected before earlier modules can be applied" {
  export DOCKER_MANUAL=yes
  run bash "$ROOT/setup.sh" --only baseline --docker --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'manual'* ]]
  [ ! -e "$XDG_STATE_HOME/vaio-fe16-dev-setup" ]
  ! grep -Eq 'apt-get .*--yes|sudo |systemctl .* (enable|start|restart|mask)' "$PROBE_LOG"
}
