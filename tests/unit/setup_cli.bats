#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home" PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export PROBE_LOG="$BATS_TEST_TMPDIR/mutations" PREFLIGHT_FIXTURES="$BATS_TEST_TMPDIR"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/os-release" <<'EOF'
ID=linuxmint
VERSION_ID="22.3"
UBUNTU_CODENAME=noble
EOF
  cat >"$BATS_TEST_TMPDIR/meminfo" <<'EOF'
MemTotal:       24576000 kB
EOF
  cat >"$BATS_TEST_TMPDIR/bin/cat" <<'EOF'
#!/bin/sh
case "$1" in
  /etc/os-release) exec /usr/bin/cat "$PREFLIGHT_FIXTURES/os-release" ;;
  /proc/meminfo) exec /usr/bin/cat "$PREFLIGHT_FIXTURES/meminfo" ;;
esac
exec /usr/bin/cat "$@"
EOF
  cat >"$BATS_TEST_TMPDIR/bin/probe" <<'EOF'
#!/bin/sh
case "${0##*/}" in
  id) echo 1000 ;;
  uname) echo x86_64 ;;
  nproc) echo 16 ;;
  df) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda2 100000000 40000000 60000000 40%% /\n' ;;
  lsblk) echo ssd ;;
  findmnt) echo /dev/sda2 ;;
  glxinfo) echo 'OpenGL renderer string: AMD Radeon Graphics' ;;
  dpkg-query|systemctl) exit 1 ;;
  swapon) : ;;
  sudo|apt-get|tee) echo "$*" >>"$PROBE_LOG"; exit 99 ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/cat" "$BATS_TEST_TMPDIR/bin/probe"
  for name in id uname nproc df lsblk findmnt glxinfo dpkg-query systemctl swapon sudo apt-get tee; do
    ln -s probe "$BATS_TEST_TMPDIR/bin/$name"
  done
}

assert_read_only() {
  [ ! -e "$PROBE_LOG" ]
  [ -z "$(ls -A "$HOME")" ]
}

@test "check reports host facts and conflicts without mutation" {
  run bash "$ROOT/setup.sh" --check
  [ "$status" -eq 0 ]
  [[ "$output" == *'os_id=linuxmint'* ]]
  [[ "$output" == *'cpu_threads=16'* ]]
  [[ "$output" == *'docker_provider=none'* ]]
  assert_read_only
}

@test "dry run previews selected operations and no opt-in defaults" {
  run bash "$ROOT/setup.sh" --dry-run --yes --docker --zram --swappiness 80
  [ "$status" -eq 0 ]
  [[ "$output" == *'module=docker'* ]]
  [[ "$output" == *'module=zram'* ]]
  [[ "$output" == *'module=baseline'* ]]
  [[ "$output" == *'module=kvm'* ]]
  [[ "$output" == *'module=mise'* ]]
  [[ "$output" == *'module=wrappers'* ]]
  [[ "$output" == *'vm.swappiness=80'* ]]
  [[ "$output" == *'sudo apt-get'* ]]
  assert_read_only

  run bash "$ROOT/setup.sh" --dry-run --yes
  [ "$status" -eq 0 ]
  [[ "$output" != *'module=docker'* ]]
  [[ "$output" != *'module=zram'* ]]
  [[ "$output" != *'module=earlyoom'* ]]
  [[ "$output" != *'module=gradle-global'* ]]
  [[ "$output" != *'vm.swappiness='* ]]
  assert_read_only
}

@test "check and dry run are mutually exclusive" {
  run bash "$ROOT/setup.sh" --check --dry-run
  [ "$status" -eq 2 ]
  run bash "$ROOT/setup.sh" --dry-run --check
  [ "$status" -eq 2 ]
  assert_read_only
}

@test "all opt ins and skip aliases are parsed without writes" {
  run bash "$ROOT/setup.sh" --dry-run --earlyoom --gradle-global --skip-mise --skip kvm --swappiness 0
  [ "$status" -eq 0 ]
  [[ "$output" == *'module=earlyoom'* ]]
  [[ "$output" == *'module=gradle-global'* ]]
  [[ "$output" == *'vm.swappiness=0'* ]]
  [[ "$output" != *'module=mise'* ]]
  [[ "$output" != *'module=kvm'* ]]
  run bash "$ROOT/setup.sh" --dry-run --no-docker --no-earlyoom
  [ "$status" -eq 0 ]
  [[ "$output" != *'module=docker'* ]]
  [[ "$output" != *'module=earlyoom'* ]]
  assert_read_only
}

@test "only and skip select modules and reject overlap" {
  run bash "$ROOT/setup.sh" --dry-run --only docker,mise --skip mise
  [ "$status" -eq 2 ]
  run bash "$ROOT/setup.sh" --dry-run --only docker
  [ "$status" -eq 0 ]
  [[ "$output" == *'module=docker'* ]]
  [[ "$output" != *'module=mise'* ]]
  assert_read_only
}

@test "unsupported platform root and invalid options fail" {
  printf 'ID=ubuntu\nVERSION_ID=24.04\n' >"$BATS_TEST_TMPDIR/os-release"
  run bash "$ROOT/setup.sh" --check
  [ "$status" -ne 0 ]
  printf 'ID=linuxmint\nVERSION_ID=22.3\nUBUNTU_CODENAME=noble\n' >"$BATS_TEST_TMPDIR/os-release"
  rm "$BATS_TEST_TMPDIR/bin/id"
  cat >"$BATS_TEST_TMPDIR/bin/id" <<'EOF'
#!/bin/sh
echo 0
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/id"
  run bash "$ROOT/setup.sh" --check
  [ "$status" -ne 0 ]
  rm "$BATS_TEST_TMPDIR/bin/id"
  ln -s probe "$BATS_TEST_TMPDIR/bin/id"
  run bash "$ROOT/setup.sh" --bogus
  [ "$status" -eq 2 ]
  run bash "$ROOT/setup.sh" --dry-run --swappiness 201
  [ "$status" -eq 2 ]
  run bash "$ROOT/setup.sh" --dry-run --docker --no-docker
  [ "$status" -eq 2 ]
  assert_read_only
}
