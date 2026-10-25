#!/usr/bin/env bats

setup() {
  [[ ${VAIO_SETUP_TEST_VM:-} == 1 ]] || skip 'Set VAIO_SETUP_TEST_VM=1 only inside the disposable VM.'
  [[ $(hostname) == vaio-fe16-test-vm && $(cat /proc/1/comm) == systemd ]] || skip 'Run only in the disposable systemd VM.'
  command -v systemd-detect-virt >/dev/null && systemd-detect-virt --vm >/dev/null || skip 'Disposable VM detection failed.'
  ROOT=$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)
  export HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  mkdir -p "$HOME"
  chmod 700 "$(dirname "$BATS_TEST_TMPDIR")" "$BATS_TEST_TMPDIR" "$HOME"
  printf 'user-owned line\n' >"$HOME/.bashrc"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/cat" <<'EOF'
#!/bin/sh
if [ "${1:-}" = /etc/os-release ]; then
  printf 'ID=linuxmint\nVERSION_ID="22.3"\nUBUNTU_CODENAME=noble\n'
else
  exec /bin/cat "$@"
fi
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/cat"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "setup wrapper installation is repeatable and rollback restores prior user files" {
  run bash "$ROOT/setup.sh" --only wrappers --yes
  [ "$status" -eq 0 ]
  first_run=$(sed -n 's/^run_id=//p' <<<"$output" | head -n 1)
  [[ $first_run =~ ^[0-9]{20}-[0-9a-f]{16}$ ]]
  [ -x "$HOME/.local/bin/dev-run" ]
  [ "$(grep -Fc '# >>> vaio-fe16 user wrappers >>>' "$HOME/.bashrc")" -eq 1 ]
  grep -Fxq 'user-owned line' "$HOME/.bashrc"

  cp "$HOME/.local/bin/dev-run" "$BATS_TEST_TMPDIR/dev-run.saved"
  printf '\n# user edit\n' >>"$HOME/.local/bin/dev-run"
  run "$ROOT/bin/dev-rollback" "$first_run" --dry-run
  [ "$status" -ne 0 ]
  grep -Fq '# user edit' "$HOME/.local/bin/dev-run"
  cp "$BATS_TEST_TMPDIR/dev-run.saved" "$HOME/.local/bin/dev-run"

  run "$ROOT/bin/dev-rollback" "$first_run" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/.local/bin/dev-run" ]
  [ "$(cat "$HOME/.bashrc")" = 'user-owned line' ]

  run bash "$ROOT/setup.sh" --only wrappers --yes
  [ "$status" -eq 0 ]
  run bash "$ROOT/setup.sh" --only wrappers --yes
  [ "$status" -eq 0 ]
  [ "$(grep -Fc '# >>> vaio-fe16 user wrappers >>>' "$HOME/.bashrc")" -eq 1 ]
  [ -x "$HOME/.local/bin/dev-run" ]
}
