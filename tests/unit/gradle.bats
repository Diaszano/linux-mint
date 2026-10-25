#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  GRADLE_TEST_ROOT=$(mktemp -d /tmp/vaio-gradle-test.XXXXXXXX)
  export HOME="$GRADLE_TEST_ROOT/home" GRADLE_USER_HOME="$GRADLE_TEST_ROOT/custom-gradle"
  export XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$HOME" "$GRADLE_USER_HOME"
  chmod 700 "$GRADLE_TEST_ROOT" "$HOME" "$GRADLE_USER_HOME"
  printf 'org.gradle.logging.level=info\ncustom.value=keep\n' >"$GRADLE_USER_HOME/gradle.properties"
  chmod 640 "$GRADLE_USER_HOME/gradle.properties"
  source "$ROOT/lib/backup.sh"
  source "$ROOT/lib/gradle.sh"
  RUN_ID=$(begin_run)
}

teardown() { rm -rf -- "$GRADLE_TEST_ROOT"; }

@test "default and plan output never write Gradle files or project files" {
  mkdir -p "$BATS_TEST_TMPDIR/project"
  printf 'org.gradle.jvmargs=-Xmx1g\n' >"$BATS_TEST_TMPDIR/project/gradle.properties"
  before=$(sha256sum "$GRADLE_USER_HOME/gradle.properties" "$BATS_TEST_TMPDIR/project/gradle.properties")

  run gradle_plan
  [ "$status" -eq 0 ]
  [[ "$output" == *'--no-daemon'* ]]
  [[ "$output" == *'Dica por projeto'* ]]
  [ "$before" = "$(sha256sum "$GRADLE_USER_HOME/gradle.properties" "$BATS_TEST_TMPDIR/project/gradle.properties")" ]
  [ ! -e "$GRADLE_TEST_ROOT/home/.gradle/gradle.properties" ]
}

@test "global plan honors GRADLE_USER_HOME and needs explicit confirmation to apply" {
  run gradle_plan --global
  [ "$status" -eq 0 ]
  [[ "$output" == *"$GRADLE_USER_HOME/gradle.properties"* ]]
  [[ "$output" == *'plan_token='* ]]
  before=$(sha256sum "$GRADLE_USER_HOME/gradle.properties")

  run gradle_global_apply "$RUN_ID"
  [ "$status" -ne 0 ]
  [ "$before" = "$(sha256sum "$GRADLE_USER_HOME/gradle.properties")" ]
}

@test "approved global settings preserve bytes, mode and unrelated keys" {
  before=$(stat -c '%a:%u:%g' "$GRADLE_USER_HOME/gradle.properties")
  gradle_plan --global >/dev/null
  token=$GRADLE_PLAN_TOKEN
  run gradle_global_apply "$RUN_ID" --gradle-global --confirmed "$token"
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a:%u:%g' "$GRADLE_USER_HOME/gradle.properties")" = "$before" ]
  grep -Fxq 'org.gradle.logging.level=info' "$GRADLE_USER_HOME/gradle.properties"
  grep -Fxq 'custom.value=keep' "$GRADLE_USER_HOME/gradle.properties"
  grep -Fxq 'org.gradle.workers.max=4' "$GRADLE_USER_HOME/gradle.properties"
  grep -Fxq 'org.gradle.caching=true' "$GRADLE_USER_HOME/gradle.properties"
  grep -Fxq 'org.gradle.daemon.idletimeout=900000' "$GRADLE_USER_HOME/gradle.properties"
  grep -Fq -- '-Xmx3g -XX:MaxMetaspaceSize=768m' "$GRADLE_USER_HOME/gradle.properties"
  ! grep -Eq '^org\.gradle\.(parallel|configuration-cache)=' "$GRADLE_USER_HOME/gradle.properties"
}

@test "outside same-key conflicts refuse to shadow existing settings" {
  printf 'org.gradle.workers.max=2\n' >>"$GRADLE_USER_HOME/gradle.properties"
  before=$(sha256sum "$GRADLE_USER_HOME/gradle.properties")
  run gradle_plan --global
  [ "$status" -ne 0 ]
  [[ "$output" == *'conflicting'* ]]
  [ "$before" = "$(sha256sum "$GRADLE_USER_HOME/gradle.properties")" ]
}

@test "Java-properties syntax and escaped keys are treated as conflicts" {
  printf 'org\\.gradle\\.workers\\.max: 2\n' >"$GRADLE_USER_HOME/gradle.properties"
  run gradle_plan --global
  [ "$status" -ne 0 ]
}

@test "continued Java-properties keys cannot hide managed conflicts" {
  printf 'org.gradle.workers.\\\n  max=2\n' >"$GRADLE_USER_HOME/gradle.properties"
  before=$(sha256sum "$GRADLE_USER_HOME/gradle.properties")
  run gradle_plan --global
  [ "$status" -ne 0 ]
  [[ "$output" == *'conflicting'* ]]
  [ "$before" = "$(sha256sum "$GRADLE_USER_HOME/gradle.properties")" ]
}

@test "empty continuation cannot turn a marker into a block boundary" {
  printf '\\\n%s\norg.gradle.workers.max=2\n%s\n' \
    "$_GRADLE_BEGIN" "$_GRADLE_END" >"$GRADLE_USER_HOME/gradle.properties"
  before=$(sha256sum "$GRADLE_USER_HOME/gradle.properties")
  run gradle_plan --global
  [ "$status" -ne 0 ]
  [[ "$output" == *'conflicting'* ]]
  [ "$before" = "$(sha256sum "$GRADLE_USER_HOME/gradle.properties")" ]
}

@test "group-writable user-home ancestors refuse preview and apply" {
  mkdir -p "$GRADLE_TEST_ROOT/unsafe-parent/gradle-home"
  chmod 777 "$GRADLE_TEST_ROOT/unsafe-parent"
  chmod 700 "$GRADLE_TEST_ROOT/unsafe-parent/gradle-home"
  if GRADLE_USER_HOME="$GRADLE_TEST_ROOT/unsafe-parent/gradle-home" gradle_plan --global >"$BATS_TEST_TMPDIR/unsafe-preview" 2>&1; then
    return 1
  fi
  grep -q 'unsafe permissions' "$BATS_TEST_TMPDIR/unsafe-preview"
  [ ! -e "$GRADLE_TEST_ROOT/unsafe-parent/gradle-home/gradle.properties" ]
}

@test "identical second apply is a no-op" {
  gradle_plan --global >/dev/null
  token=$GRADLE_PLAN_TOKEN
  gradle_global_apply "$RUN_ID" --gradle-global --confirmed "$token"
  before=$(stat -c '%i:%Y:%s' "$GRADLE_USER_HOME/gradle.properties")
  gradle_plan --global >/dev/null
  gradle_global_apply "$RUN_ID" --gradle-global --confirmed "$GRADLE_PLAN_TOKEN"
  [ "$before" = "$(stat -c '%i:%Y:%s' "$GRADLE_USER_HOME/gradle.properties")" ]
}

@test "later edits to the managed block block rollback" {
  gradle_plan --global >/dev/null
  gradle_global_apply "$RUN_ID" --gradle-global --confirmed "$GRADLE_PLAN_TOKEN"
  printf '# user change\n' >>"$GRADLE_USER_HOME/gradle.properties"
  run "$ROOT/bin/dev-rollback" "$RUN_ID" --yes
  [ "$status" -ne 0 ]
  [[ "${output,,}" == *'manual'* || "${output,,}" == *'conflict'* ]]
  grep -Fxq 'custom.value=keep' "$GRADLE_USER_HOME/gradle.properties"
  grep -Fq '# user change' "$GRADLE_USER_HOME/gradle.properties"
}

@test "user project properties remain untouched by global apply" {
  mkdir -p "$BATS_TEST_TMPDIR/project"
  printf 'project.value=leave-me\n' >"$BATS_TEST_TMPDIR/project/gradle.properties"
  before=$(sha256sum "$BATS_TEST_TMPDIR/project/gradle.properties")
  gradle_plan --global >/dev/null
  gradle_global_apply "$RUN_ID" --gradle-global --confirmed "$GRADLE_PLAN_TOKEN"
  [ "$before" = "$(sha256sum "$BATS_TEST_TMPDIR/project/gradle.properties")" ]
}

@test "missing global file is journaled and removed by rollback" {
  rm "$GRADLE_USER_HOME/gradle.properties"
  gradle_plan --global >/dev/null
  gradle_global_apply "$RUN_ID" --gradle-global --confirmed "$GRADLE_PLAN_TOKEN"
  grep -Fxq 'org.gradle.workers.max=4' "$GRADLE_USER_HOME/gradle.properties"
  run "$ROOT/bin/dev-rollback" "$RUN_ID" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$GRADLE_USER_HOME/gradle.properties" ]
}
