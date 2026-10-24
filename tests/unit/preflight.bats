#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home" PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/os-release" <<'EOF'
ID=linuxmint
VERSION_ID="22.3"
UBUNTU_CODENAME=noble
EOF
  cat >"$BATS_TEST_TMPDIR/meminfo" <<'EOF'
MemTotal:       24576000 kB
EOF
  cat >"$BATS_TEST_TMPDIR/controllers" <<'EOF'
cpuset cpu io memory hugetlb pids
EOF
  cat >"$BATS_TEST_TMPDIR/cpuinfo" <<'EOF'
flags : fpu svm
EOF
  cat >"$BATS_TEST_TMPDIR/bin/cat" <<'EOF'
#!/bin/sh
case "$1" in
  /etc/os-release) exec /usr/bin/cat "$PREFLIGHT_FIXTURES/os-release" ;;
  /proc/meminfo) exec /usr/bin/cat "$PREFLIGHT_FIXTURES/meminfo" ;;
  /sys/fs/cgroup/cgroup.controllers) exec /usr/bin/cat "$PREFLIGHT_FIXTURES/controllers" ;;
  /proc/cpuinfo) exec /usr/bin/cat "$PREFLIGHT_FIXTURES/cpuinfo" ;;
esac
exec /usr/bin/cat "$@"
EOF
  cat >"$BATS_TEST_TMPDIR/bin/probe" <<'EOF'
#!/bin/sh
case "${0##*/}" in
  uname) echo x86_64 ;;
  nproc) echo 16 ;;
  df) printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda2 100000000 40000000 60000000 40%% /\n' ;;
  lsblk) echo ssd ;;
  findmnt) echo /dev/sda2 ;;
  glxinfo) echo 'OpenGL renderer string: AMD Radeon Graphics' ;;
  dpkg-query)
    case "$*" in
      *zram-tools*|*earlyoom*|*docker.io*) echo 'install ok installed' ;;
      *) exit 1 ;;
    esac ;;
  systemctl)
    case "$*" in
      *zramswap*|*earlyoom*|*systemd-oomd*) echo active ;;
      *) echo inactive ;;
    esac ;;
  swapon) echo '/dev/zram0 partition 4G 100' ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/cat" "$BATS_TEST_TMPDIR/bin/probe"
  for name in uname nproc df lsblk findmnt glxinfo dpkg-query systemctl swapon; do
    ln -s probe "$BATS_TEST_TMPDIR/bin/$name"
  done
  export PREFLIGHT_FIXTURES="$BATS_TEST_TMPDIR"
}

@test "host discovery reports Mint Noble hardware and capabilities" {
  run bash -c 'source "$1/lib/preflight.sh"; preflight_host' _ "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'os_id=linuxmint'* ]]
  [[ "$output" == *'os_version=22.3'* ]]
  [[ "$output" == *'ubuntu_codename=noble'* ]]
  [[ "$output" == *'arch=x86_64'* ]]
  [[ "$output" == *'cpu_threads=16'* ]]
  [[ "$output" == *'mem_total_kb=24576000'* ]]
  [[ "$output" == *'storage_free_kb=60000000'* ]]
  [[ "$output" == *'storage_type=ssd'* ]]
  [[ "$output" == *'cgroup_controllers='*cpu*memory*pids* ]]
  [[ "$output" == *'cpu_virtualization=svm'* ]]
  [[ "$output" == *'mesa_renderer=AMD Radeon Graphics'* ]]
}

@test "conflict discovery reports existing managers and Docker provider" {
  run bash -c 'source "$1/lib/preflight.sh"; preflight_conflicts' _ "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'zram_tools_installed=yes'* ]]
  [[ "$output" == *'zramswap_active=yes'* ]]
  [[ "$output" == *'swap_devices=/dev/zram0'* ]]
  [[ "$output" == *'earlyoom_installed=yes'* ]]
  [[ "$output" == *'earlyoom_active=yes'* ]]
  [[ "$output" == *'systemd_oomd_active=yes'* ]]
  [[ "$output" == *'docker_provider=docker.io'* ]]
}
