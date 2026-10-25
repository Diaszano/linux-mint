#!/usr/bin/env bats

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export MISE_TEST_FIXTURE="$BATS_TEST_TMPDIR/release" MISE_TEST_LOG="$BATS_TEST_TMPDIR/curl.log"
  export MISE_EXEC_LOG="$BATS_TEST_TMPDIR/mise-exec.log"
  MISE_TEST_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$HOME/.local/bin" "$MISE_TEST_FIXTURE" "$MISE_TEST_BIN"
  cat >"$MISE_TEST_FIXTURE/mise-v2026.10.18-linux-x64" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_EXEC_LOG"
case "$1" in
  --version) printf 'mise version 2026.10.18\n' ;;
  activate) printf 'export MISE_TEST_ACTIVATED=1\n' ;;
  *) exit 2 ;;
esac
EOF
  chmod 755 "$MISE_TEST_FIXTURE/mise-v2026.10.18-linux-x64"
  sha256sum "$MISE_TEST_FIXTURE/mise-v2026.10.18-linux-x64" | sed "s#  .*/#  ./#" >"$MISE_TEST_FIXTURE/SHASUMS256.txt"
  printf 'valid signature\n' >"$MISE_TEST_FIXTURE/SHASUMS256.txt.minisig"
  cat >"$MISE_TEST_BIN/curl" <<'EOF'
#!/bin/sh
out=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output|-o) out=$2; shift 2 ;;
    https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
name=${url##*/}
printf '%s\n' "$url" >>"$MISE_TEST_LOG"
[ -n "$out" ] && [ -f "$MISE_TEST_FIXTURE/$name" ] || exit 22
cp -- "$MISE_TEST_FIXTURE/$name" "$out"
EOF
  cat >"$MISE_TEST_BIN/minisign" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$MISE_TEST_LOG"
case "$*" in *'-P RWTC3g8W3z4RZK3V3qv7fa1QY4JEWyBtqIHW+85QlJpZc5yG+uNYNBSZ'*) ;; *) exit 1 ;; esac
grep -q '^valid signature$' "$MISE_TEST_FIXTURE/SHASUMS256.txt.minisig"
EOF
  chmod 755 "$MISE_TEST_BIN/curl" "$MISE_TEST_BIN/minisign"
  export PATH="$MISE_TEST_BIN:/usr/local/bin:/usr/bin:/bin"
}

@test "mise found on PATH is reused without download or execution" {
  touch "$HOME/.bashrc"
  cat >"$HOME/.local/bin/mise" <<'EOF'
#!/bin/sh
echo must-not-run >>"$MISE_EXEC_LOG"
EOF
  chmod 755 "$HOME/.local/bin/mise"

  run bash -c 'source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_plan; mise_apply "$id"' _ "$ROOT"

  [ "$status" -eq 0 ]
  [[ "$output" == *"$HOME/.local/bin/mise"* ]]
  [ ! -e "$MISE_TEST_LOG" ]
  [ ! -e "$MISE_EXEC_LOG" ]
  [ -x "$HOME/.local/bin/mise" ]
}

@test "unsafe existing mise target is refused before download" {
  touch "$HOME/.bashrc"
  printf 'do-not-replace\n' >"$BATS_TEST_TMPDIR/other-mise"
  chmod 755 "$BATS_TEST_TMPDIR/other-mise"
  ln -s "$BATS_TEST_TMPDIR/other-mise" "$HOME/.local/bin/mise"
  run bash -c 'set -e; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_apply "$id"' _ "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *'will not be replaced'* ]]
  [ ! -e "$MISE_TEST_LOG" ]
  [ ! -e "$MISE_EXEC_LOG" ]
  [ "$(cat "$BATS_TEST_TMPDIR/other-mise")" = do-not-replace ]
}

@test "signed release is verified before install and digest is journaled" {
  touch "$HOME/.bashrc" "$HOME/.zshrc"

  run bash -c 'set -e; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_apply "$id"; printf "%s\n" "$id"' _ "$ROOT"

  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/mise" ]
  [ "$(cat "$MISE_EXEC_LOG")" = --version ]
  [ "$(grep -c 'mise activate bash' "$HOME/.bashrc")" -eq 1 ]
  [ "$(grep -c 'mise activate zsh' "$HOME/.zshrc")" -eq 1 ]
  grep -q 'SHASUMS256.txt.minisig' "$MISE_TEST_LOG"
  grep -q 'mise-v2026.10.18-linux-x64' "$MISE_TEST_LOG"
  run python3 -c 'import json,sys; e=[json.loads(x) for x in open(sys.argv[1])]; assert any(x.get("event")=="artifact" and x.get("sha256") for x in e)' "$XDG_STATE_HOME/vaio-fe16-dev-setup/runs/$(find "$XDG_STATE_HOME/vaio-fe16-dev-setup/runs" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')/manifest.jsonl"
  [ "$status" -eq 0 ]
}

@test "bad signature refuses before installation or binary execution" {
  touch "$HOME/.bashrc"
  printf 'invalid signature\n' >"$MISE_TEST_FIXTURE/SHASUMS256.txt.minisig"
  run bash -c 'set -e; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_apply "$id"' _ "$ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *manual* ]]
  [ ! -e "$HOME/.local/bin/mise" ]
  [ ! -e "$MISE_EXEC_LOG" ]
}

@test "missing signature checksum asset or network refuses with manual guidance" {
  touch "$HOME/.bashrc"
  local original="$BATS_TEST_TMPDIR/release-original"
  cp -a "$MISE_TEST_FIXTURE" "$original"

  rm "$MISE_TEST_FIXTURE/SHASUMS256.txt.minisig"
  run bash -c 'set -e; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_apply "$id"' _ "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *manual* ]]
  [ ! -e "$HOME/.local/bin/mise" ]
  [ ! -e "$MISE_EXEC_LOG" ]

  cp "$original/SHASUMS256.txt.minisig" "$MISE_TEST_FIXTURE/SHASUMS256.txt.minisig"
  printf '%064d  another-file\n' 0 >"$MISE_TEST_FIXTURE/SHASUMS256.txt"
  run bash -c 'set -e; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_apply "$id"' _ "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *manual* ]]
  [ ! -e "$HOME/.local/bin/mise" ]
  [ ! -e "$MISE_EXEC_LOG" ]

  cp "$original/SHASUMS256.txt" "$MISE_TEST_FIXTURE/SHASUMS256.txt"
  rm "$MISE_TEST_FIXTURE/mise-v2026.10.18-linux-x64"
  run bash -c 'set -e; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_apply "$id"' _ "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *manual* ]]
  [ ! -e "$HOME/.local/bin/mise" ]
  [ ! -e "$MISE_EXEC_LOG" ]

  cat >"$MISE_TEST_BIN/curl" <<'EOF'
#!/bin/sh
exit 7
EOF
  chmod 755 "$MISE_TEST_BIN/curl"
  run bash -c 'set -e; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_apply "$id"' _ "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *manual* ]]
  [ ! -e "$HOME/.local/bin/mise" ]
  [ ! -e "$MISE_EXEC_LOG" ]
}

@test "missing minisign refuses before network or mise execution" {
  touch "$HOME/.bashrc"
  rm "$MISE_TEST_BIN/minisign"
  ln -s "$(command -v dirname)" "$MISE_TEST_BIN/dirname"
  ln -s "$(command -v python3)" "$MISE_TEST_BIN/python3"
  ln -s "$(command -v id)" "$MISE_TEST_BIN/id"
  run /usr/bin/bash -c 'PATH=$2; export PATH; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; apt_plan() { return 1; }; id=$(begin_run); mise_apply "$id"' _ "$ROOT" "$MISE_TEST_BIN"
  [ "$status" -ne 0 ]
  [[ "$output" == *'minisign is unavailable'* ]]
  [ ! -e "$MISE_TEST_LOG" ]
  [ ! -e "$HOME/.local/bin/mise" ]
  [ ! -e "$MISE_EXEC_LOG" ]
}

@test "successful distro minisign install precedes release verification" {
  touch "$HOME/.bashrc"
  MISE_MINISIGN_FIXTURE="$BATS_TEST_TMPDIR/minisign.fixture"
  mv "$MISE_TEST_BIN/minisign" "$MISE_MINISIGN_FIXTURE"
  MISE_TEST_NOMINISIGN_BIN="$BATS_TEST_TMPDIR/no-minisign-bin"
  mkdir -p "$MISE_TEST_NOMINISIGN_BIN"
  for tool in dirname python3 id stat realpath mktemp chmod sha256sum grep sed rm cp mkdir; do
    ln -s "$(command -v "$tool")" "$MISE_TEST_NOMINISIGN_BIN/$tool"
  done
  ln -s "$MISE_TEST_BIN/curl" "$MISE_TEST_NOMINISIGN_BIN/curl"
  export MISE_MINISIGN_FIXTURE
  run /usr/bin/bash -c '
    root=$1; path=$2; bin=$3
    export PATH=$path
    source "$root/lib/backup.sh"
    source "$root/lib/mise.sh"
    apt_plan() {
      [[ $1 == mise && $2 == minisign ]] || return 1
      APT_PLAN_TOKEN=test-plan-token
      printf "apt-plan %s %s\\n" "$1" "$2" >>"$MISE_TEST_LOG"
    }
    apt_apply() {
      [[ $# == 5 && $2 == mise && $3 == --confirmed && $4 == test-plan-token && $5 == minisign ]] || return 1
      printf "apt-apply %s %s\\n" "$2" "$5" >>"$MISE_TEST_LOG"
      cp "$MISE_MINISIGN_FIXTURE" "$bin/minisign"
      chmod 755 "$bin/minisign"
    }
    run_id=$(begin_run)
    mise_apply "$run_id"
  ' _ "$ROOT" "$MISE_TEST_NOMINISIGN_BIN" "$MISE_TEST_NOMINISIGN_BIN"
  [ "$status" -eq 0 ]
  [ -x "$HOME/.local/bin/mise" ]
  [ "$(cat "$MISE_EXEC_LOG")" = --version ]
  [ "$(sed -n '1p' "$MISE_TEST_LOG")" = 'apt-plan mise minisign' ]
  [ "$(sed -n '2p' "$MISE_TEST_LOG")" = 'apt-apply mise minisign' ]
  [[ "$(sed -n '3p' "$MISE_TEST_LOG")" == https://github.com/jdx/mise/releases/download/*/SHASUMS256.txt ]]
  [[ "$(sed -n '6p' "$MISE_TEST_LOG")" == '-Vm '* ]]
  [ "$(grep -c '^https://' "$MISE_TEST_LOG")" -eq 3 ]
}

@test "changed artifact bytes fail hash verification before installation" {
  touch "$HOME/.bashrc"
  cat >"$MISE_TEST_BIN/curl" <<'EOF'
#!/bin/sh
out=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in --output|-o) out=$2; shift 2 ;; https://*) url=$1; shift ;; *) shift ;; esac
done
name=${url##*/}
printf '%s\n' "$url" >>"$MISE_TEST_LOG"
[ -f "$MISE_TEST_FIXTURE/$name" ] || exit 22
cp -- "$MISE_TEST_FIXTURE/$name" "$out"
if [ "$name" = mise-v2026.10.18-linux-x64 ]; then printf '\nchanged\n' >>"$out"; fi
EOF
  chmod 755 "$MISE_TEST_BIN/curl"

  run bash -c 'set -e; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_apply "$id"' _ "$ROOT"

  [ "$status" -ne 0 ]
  [[ "$output" == *hash* || "$output" == *digest* ]]
  [[ "$output" == *manual* ]]
  [ ! -e "$HOME/.local/bin/mise" ]
  [ ! -e "$MISE_EXEC_LOG" ]
}

@test "minisign is selected only when mise is absent" {
  rm "$MISE_TEST_BIN/minisign"
  ln -s "$(command -v dirname)" "$MISE_TEST_BIN/dirname"
  run /usr/bin/bash -c 'PATH=$2; export PATH; source "$1/lib/packages.sh"; package_selection mise' _ "$ROOT" "$MISE_TEST_BIN"
  [ "$status" -eq 0 ]
  [[ "$output" == *minisign* ]]

  touch "$HOME/.local/bin/mise"
  chmod 755 "$HOME/.local/bin/mise"
  run /usr/bin/bash -c 'PATH=$2; export PATH; source "$1/lib/packages.sh"; package_selection mise' _ "$ROOT" "$MISE_TEST_BIN"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "activation blocks are idempotent and fresh login shell resolves mise" {
  touch "$HOME/.bashrc" "$HOME/.zshrc"
  cat >"$HOME/.profile" <<'EOF'
if [ -n "$BASH_VERSION" ] && [ -f "$HOME/.bashrc" ]; then . "$HOME/.bashrc"; fi
EOF
  run bash -c 'set -e; source "$1/lib/backup.sh"; source "$1/lib/mise.sh"; id=$(begin_run); mise_apply "$id"; id=$(begin_run); mise_apply "$id"' _ "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(grep -c '>>> vaio-fe16 mise >>>' "$HOME/.bashrc")" -eq 1 ]
  [ "$(grep -c '>>> vaio-fe16 mise >>>' "$HOME/.zshrc")" -eq 1 ]
  run bash --login -ic 'command -v mise 2>/dev/null'
  [[ "$output" == *"$HOME/.local/bin/mise"* ]]
}
