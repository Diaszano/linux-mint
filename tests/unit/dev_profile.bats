#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export FIXTURE="$BATS_TEST_TMPDIR"
  mkdir -p "$XDG_CONFIG_HOME"
  chmod 700 "$BATS_TEST_TMPDIR" "$(dirname "$BATS_TEST_TMPDIR")"
}

@test "show reports the balanced preset and shipped workload ceilings" {
  run "$ROOT/bin/dev-profile" show
  [ "$status" -eq 0 ]
  [[ "$output" == *"balanced"* ]]
  [[ "$output" == *$'build\t800\t7\t9\t2\t1024'* ]]
  [[ "$output" == *$'emulator\t400\t5\t6\t1\t512'* ]]
  [[ "$output" == *$'heavy\t600\t6\t8\t2\t768'* ]]
  [ ! -e "$XDG_CONFIG_HOME/vaio-dev/profile" ]
}

@test "select balanced writes a private user choice without sudo" {
  mkdir -p "$FIXTURE/bin"
  for command in sudo systemctl systemd-run; do
  cat >"$FIXTURE/bin/$command" <<'SH'
#!/bin/sh
printf '%s\n' "$0 $*" >>"$FIXTURE/commands"
exit 99
SH
  chmod +x "$FIXTURE/bin/$command"
  done
  run env PATH="$FIXTURE/bin:$PATH" "$ROOT/bin/dev-profile" select balanced
  [ "$status" -eq 0 ]
  [ "$(cat "$XDG_CONFIG_HOME/vaio-dev/profile")" = balanced ]
  [ "$(stat -c %a "$XDG_CONFIG_HOME/vaio-dev/profile")" = 600 ]
  [ ! -e "$FIXTURE/commands" ]
}

@test "only the balanced preset can be selected" {
  for choice in throughput "balanced; touch $FIXTURE/pwned"; do
    run "$ROOT/bin/dev-profile" select "$choice"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Unknown command or profile"* ]]
    [ ! -e "$FIXTURE/pwned" ]
  done
  [ ! -e "$XDG_CONFIG_HOME/vaio-dev/profile" ]
}

@test "profile tables are parsed as strict data, not shell code" {
  mkdir -p "$XDG_CONFIG_HOME/vaio-dev"
  printf 'build\t800\t7\t9\t2\t1024\n' >"$XDG_CONFIG_HOME/vaio-dev/profiles.conf"
  chmod 600 "$XDG_CONFIG_HOME/vaio-dev/profiles.conf"
  run "$ROOT/bin/dev-profile" show
  [ "$status" -ne 0 ]
  [[ "$output" == *"Malformed, incomplete, or empty workload table"* ]]
  printf 'build\t800\t7\t9\t2\t1024; touch %s/pwned\n' "$FIXTURE" >"$XDG_CONFIG_HOME/vaio-dev/profiles.conf"
  run "$ROOT/bin/dev-profile" show
  [ "$status" -ne 0 ]
  [[ "$output" == *"Malformed, incomplete, or empty workload table"* ]]
  [ ! -e "$FIXTURE/pwned" ]
}

@test "incomplete user table refuses selection without changing prior choice" {
  mkdir -p "$XDG_CONFIG_HOME/vaio-dev"
  chmod 700 "$XDG_CONFIG_HOME/vaio-dev"
  printf 'balanced\n' >"$XDG_CONFIG_HOME/vaio-dev/profile"
  chmod 600 "$XDG_CONFIG_HOME/vaio-dev/profile"
  printf 'build\t800\t7\t9\t2\t1024\n' >"$XDG_CONFIG_HOME/vaio-dev/profiles.conf"
  chmod 600 "$XDG_CONFIG_HOME/vaio-dev/profiles.conf"
  before=$(sha256sum "$XDG_CONFIG_HOME/vaio-dev/profile")
  run "$ROOT/bin/dev-profile" select balanced
  [ "$status" -ne 0 ]
  [[ "$output" == *"Malformed, incomplete, or empty workload table"* ]]
  [ "$(sha256sum "$XDG_CONFIG_HOME/vaio-dev/profile")" = "$before" ]
}

@test "failed atomic replacement preserves the prior choice" {
  mkdir -p "$XDG_CONFIG_HOME/vaio-dev" "$FIXTURE/bin"
  printf 'balanced\n' >"$XDG_CONFIG_HOME/vaio-dev/profile"
  chmod 600 "$XDG_CONFIG_HOME/vaio-dev/profile"
  cat >"$FIXTURE/bin/mv" <<'SH'
#!/bin/sh
exit 1
SH
  chmod +x "$FIXTURE/bin/mv"
  run env PATH="$FIXTURE/bin:$PATH" "$ROOT/bin/dev-profile" select balanced
  [ "$status" -ne 0 ]
  [ "$(cat "$XDG_CONFIG_HOME/vaio-dev/profile")" = balanced ]
  [ "$(find "$XDG_CONFIG_HOME/vaio-dev" -maxdepth 1 -name '.profile.*' -print -quit)" = "" ]
}

@test "unsafe or malformed profile selection fails closed" {
  mkdir -p "$XDG_CONFIG_HOME/vaio-dev"
  printf 'throughput\n' >"$XDG_CONFIG_HOME/vaio-dev/profile"
  chmod 600 "$XDG_CONFIG_HOME/vaio-dev/profile"
  run "$ROOT/bin/dev-profile" show
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unsafe or unknown user profile choice"* ]]
  rm "$XDG_CONFIG_HOME/vaio-dev/profile"
  ln -s "$FIXTURE/outside" "$XDG_CONFIG_HOME/vaio-dev/profile"
  run "$ROOT/bin/dev-profile" show
  [ "$status" -ne 0 ]
}
