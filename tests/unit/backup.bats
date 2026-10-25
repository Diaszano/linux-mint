#!/usr/bin/env bats
setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$HOME"
}

@test "sourcing backup helpers creates no state" {
  run bash -c 'source "$1/lib/backup.sh"' _ "$ROOT"
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_STATE_HOME" ]
}

@test "shell helpers snapshot install and skip unchanged files without leaking content" {
  printf 'old-secret\n' > "$BATS_TEST_TMPDIR/target"
  printf 'new-secret\n' > "$BATS_TEST_TMPDIR/source"
  run bash -c 'set -e; source "$1/lib/backup.sh"; id=$(begin_run); snapshot_file "$id" baseline "$2/target"; install_owned_file "$id" baseline "$2/source" "$2/target"; install_owned_file "$id" baseline "$2/source" "$2/target"; printf "%s\n" "$id"' _ "$ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [[ "$output" != *secret* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/target")" = new-secret ]
  [ "$(wc -l < "$XDG_STATE_HOME/vaio-fe16-dev-setup/runs/$output/manifest.jsonl")" -eq 4 ]
}

@test "creating a target records absence and preserves source mode" {
  printf 'new\n' > "$BATS_TEST_TMPDIR/source"
  chmod 600 "$BATS_TEST_TMPDIR/source"
  run bash -c 'set -e; source "$1/lib/backup.sh"; id=$(begin_run); install_owned_file "$id" baseline "$2/source" "$2/new"' _ "$ROOT" "$BATS_TEST_TMPDIR"
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$BATS_TEST_TMPDIR/new")" = 600 ]
}

@test "unsafe run state and target symlinks are refused" {
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  ln -s "$BATS_TEST_TMPDIR/elsewhere" "$XDG_STATE_HOME"
  run bash -c 'source "$1/lib/backup.sh"; begin_run' _ "$ROOT"
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$BATS_TEST_TMPDIR/elsewhere")" ]
}
