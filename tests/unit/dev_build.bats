#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  FIXTURE="$BATS_TEST_TMPDIR"
  mkdir -p "$FIXTURE/bin" "$FIXTURE/project"
  [[ ! -f "$ROOT/bin/dev-build" ]] || cp "$ROOT/bin/dev-build" "$FIXTURE/bin/dev-build"
  cat >"$FIXTURE/bin/dev-run" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$FIXTURE/argv"
printf '%s\n' "${GOMAXPROCS-}" "${CARGO_BUILD_JOBS-}" "${CMAKE_BUILD_PARALLEL_LEVEL-}" >"$FIXTURE/env"
case ${FAKE_STATUS:-0} in
  signal) kill -TERM "$$" ;;
  *) exit "${FAKE_STATUS:-0}" ;;
esac
SH
  chmod +x "$FIXTURE/bin/dev-run"
  export FIXTURE
}

@test "dev-build preserves arguments and supplies only absent build concurrency defaults" {
  run "$FIXTURE/bin/dev-build" 'two words' '' '*;$(false)'
  [ "$status" = 0 ]
  mapfile -d '' -t args <"$FIXTURE/argv"
  [ "${#args[@]}" = 4 ]
  [ "${args[0]}" = build ]
  [ "${args[1]}" = 'two words' ]
  [ -z "${args[2]}" ]
  [ "${args[3]}" = '*;$(false)' ]
  run cat "$FIXTURE/env"
  [ "$output" = $'8\n4\n4' ]
}

@test "user concurrency environment overrides are preserved" {
  export GOMAXPROCS=3 CARGO_BUILD_JOBS=2 CMAKE_BUILD_PARALLEL_LEVEL=1
  run "$FIXTURE/bin/dev-build" true
  [ "$status" = 0 ]
  run cat "$FIXTURE/env"
  [ "$output" = $'3\n2\n1' ]
}

@test "payload exit status and signal status propagate" {
  export FAKE_STATUS=7
  run "$FIXTURE/bin/dev-build" true
  [ "$status" = 7 ]
  export FAKE_STATUS=signal
  run "$FIXTURE/bin/dev-build" true
  [ "$status" = 143 ]
}

@test "wrapper does not write global environment or project files" {
  printf 'org.gradle.jvmargs=-Xmx1g\n' >"$FIXTURE/project/gradle.properties"
  before=$(sha256sum "$FIXTURE/project/gradle.properties")
  run "$ROOT/bin/dev-build" true
  [ "$status" = 0 ]
  after=$(sha256sum "$FIXTURE/project/gradle.properties")
  [ "$before" = "$after" ]
}

@test "Gradle guidance uses no-daemon and describes daemon and IDE boundaries" {
  run grep -F 'dev-build ./gradlew assembleDebug --no-daemon' "$ROOT/docs/GRADLE.md"
  [ "$status" = 0 ]
  run grep -F 'single-use daemon' "$ROOT/docs/GRADLE.md"
  [ "$status" = 0 ]
  run grep -F 'outside it' "$ROOT/docs/GRADLE.md"
  [ "$status" = 0 ]
}
