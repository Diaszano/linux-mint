#!/usr/bin/env bats

setup_file() {
  export ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export LEGACY="$ROOT/legacy/vaio-fe16-dev-setup"
}

assert_source_contains() {
  run grep -F -- "$1" "$2"
  [ "$status" -eq 0 ]
}

@test "legacy setup defaults Docker and earlyoom on" {
  assert_source_contains 'WITH_DOCKER=1' "$LEGACY/setup.sh"
  assert_source_contains 'WITH_EARLYOOM=1' "$LEGACY/setup.sh"
  assert_source_contains '((WITH_DOCKER))' "$LEGACY/setup.sh"
  assert_source_contains '((WITH_EARLYOOM))' "$LEGACY/setup.sh"
}

@test "legacy setup writes user Gradle properties and two VM sysctls" {
  assert_source_contains 'GRADLE_PROPS="$HOME/.gradle/gradle.properties"' "$LEGACY/setup.sh"
  assert_source_contains "'vm.swappiness = 100' 'vm.page-cluster = 0'" "$LEGACY/setup.sh"
}

@test "legacy --check inspects source paths and exits before setup mutations" {
  assert_source_contains '[[ -d "$SCRIPT_DIR/bin" ]]' "$LEGACY/setup.sh"
  assert_source_contains 'exec bash "$SCRIPT_DIR/bin/dev-doctor"' "$LEGACY/setup.sh"
  run grep -nF 'exec bash "$SCRIPT_DIR/bin/dev-doctor"' "$LEGACY/setup.sh"
  [ "$status" -eq 0 ]
  check_line="${output%%:*}"
  run grep -nE 'sudo -v|apt-get update|apt-get install' "$LEGACY/setup.sh"
  [ "$status" -eq 0 ]
  mutation_line="${output%%:*}"
  [ "$check_line" -lt "$mutation_line" ]
}

@test "legacy dev-run requests four limits without validating kernel limit files" {
  assert_source_contains '-p "CPUQuota=${cpu}%" -p "MemoryHigh=$high" -p "MemoryMax=$max"' "$LEGACY/bin/dev-run"
  assert_source_contains '-p "TasksMax=$tasks"' "$LEGACY/bin/dev-run"
  run grep -E '(/sys/fs/cgroup|cpu\.max|memory\.(high|max|swap\.max)|pids\.max)' "$LEGACY/bin/dev-run"
  [ "$status" -eq 1 ]
}

@test "legacy dev-build preserves argument boundaries through dev-run" {
  assert_source_contains '"$@"' "$LEGACY/bin/dev-build"
  assert_source_contains 'dev-run" build "$@"' "$LEGACY/bin/dev-build"
}

@test "legacy Compose bounds services and binds only to localhost" {
  assert_source_contains "127.0.0.1:5432:5432" "$LEGACY/compose-limits.example.yaml"
  assert_source_contains "127.0.0.1:6379:6379" "$LEGACY/compose-limits.example.yaml"
  assert_source_contains 'cpus: 2.0' "$LEGACY/compose-limits.example.yaml"
  assert_source_contains 'mem_limit: 2g' "$LEGACY/compose-limits.example.yaml"
  assert_source_contains 'pids_limit: 256' "$LEGACY/compose-limits.example.yaml"
  assert_source_contains 'cpus: 1.0' "$LEGACY/compose-limits.example.yaml"
  assert_source_contains 'mem_limit: 512m' "$LEGACY/compose-limits.example.yaml"
  assert_source_contains 'pids_limit: 128' "$LEGACY/compose-limits.example.yaml"
}
