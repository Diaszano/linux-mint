#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
}

@test "README documents every setup option exposed by help" {
    local help option
    help=$(bash "$ROOT/setup.sh" --help)
    while IFS= read -r option; do
        [[ -z $option ]] && continue
        [[ "$(cat "$ROOT/README.md" "$ROOT/docs/USAGE.md")" == *"$option"* ]]
    done < <(sed -nE 's/^[[:space:]]*(--[a-z][a-z-]*).*/\1/p' <<<"$help")
}

@test "persistent modules document their rollback and package limits" {
    local docs="$ROOT/docs/USAGE.md"
    for phrase in 'baseline' 'kvm' 'mise' 'wrappers' 'zram' 'docker' 'gradle-global' 'swappiness'; do
        grep -Fqi "| \`$phrase\` |" "$docs"
    done
    grep -Fqi '| `earlyoom` |' "$docs"
    grep -Fqi '| Persistent module |' "$docs"
    grep -Eqi 'checksum|checksummed' "$docs"
    grep -Eqi 'manual review.*package|package.*manual review' "$docs"
    grep -Eqi 'manifest|run id' "$docs"
}

@test "documents keep optional changes off and earlyoom unavailable" {
    local docs
    docs=$(cat "$ROOT/README.md" "$ROOT/docs/USAGE.md")
    [[ "$docs" == *'--docker'* && "$docs" == *'docker'* && "$docs" == *'default'* ]]
    [[ "$docs" == *'--zram'* && "$docs" == *'zram'* && "$docs" == *'default'* ]]
    [[ "$docs" == *'--earlyoom'* && "$docs" == *'unavailable'* ]]
    [[ "$docs" == *'--gradle-global'* && "$docs" == *'global Gradle'* ]]
    [[ "$docs" == *'swappiness'* && "$docs" == *'sysctl'* ]]
    [[ "$docs" == *'not enabled by default'* || "$docs" == *'off by default'* ]]
}

@test "technical docs are English and preserve the legacy README" {
    local file
    for file in "$ROOT/README.md" "$ROOT/docs/USAGE.md" "$ROOT/docs/PERFORMANCE.md" "$ROOT/docs/TROUBLESHOOTING.md"; do
        [ -f "$file" ]
        ! grep -Eiq '\b(não|instalação|configuração|falha|usuário|memória)\b' "$file"
    done
    (cd "$ROOT" && sha256sum -c tests/fixtures/legacy.sha256 >/dev/null)
}

@test "docs avoid unsupported performance and IDE or reused-daemon guarantees" {
    local docs
    docs=$(cat "$ROOT/README.md" "$ROOT/docs/USAGE.md" "$ROOT/docs/PERFORMANCE.md")
    [[ "$docs" == *'no performance improvement is claimed'* || "$docs" == *'no performance improvements are claimed'* ]]
    [[ "$docs" == *'provisional'* ]]
    [[ "$docs" == *'Android Studio'* && "$docs" == *'outside'* ]]
    [[ "$docs" == *'reused'* && "$docs" == *'daemon'* ]]
}

@test "docs capture Gradle, KVM, Docker and signed mise boundaries" {
    local docs
    docs=$(cat "$ROOT/README.md" "$ROOT/docs/USAGE.md" "$ROOT/docs/PERFORMANCE.md")
    [[ "$docs" == *'--no-daemon'* ]]
    [[ "$docs" == *'-accel on'* && "$docs" == *'x86_64'* && "$docs" == *'KVM'* ]]
    [[ "$docs" == *'GPU'* && "$docs" == *'swiftshader'* ]]
    [[ "$docs" == *'rootless'* && "$docs" == *'cgroup'* ]]
    [[ "$docs" == *'minisign'* && "$docs" == *'RWTC3g8W3z4RZK3V3qv7fa1QY4JEWyBtqIHW+85QlJpZc5yG+uNYNBSZ'* ]]
}

@test "VM runner requires deliberate opt-in and a virtual machine check" {
    [ -x "$ROOT/tests/integration/run-vm.sh" ]
    grep -Fq 'VAIO_TEST_VM' "$ROOT/tests/integration/run-vm.sh"
    grep -Fq 'systemd-detect-virt --vm' "$ROOT/tests/integration/run-vm.sh"

    run env -u VAIO_TEST_VM "$ROOT/tests/integration/run-vm.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *'disposable VM'* ]]

    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/systemd-detect-virt" <<'EOF'
#!/bin/sh
exit 1
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/systemd-detect-virt"
    run env VAIO_TEST_VM=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$ROOT/tests/integration/run-vm.sh"
    [ "$status" -eq 2 ]
    [[ "$output" == *'does not identify this environment as a VM'* ]]

    cat >"$BATS_TEST_TMPDIR/bin/systemd-detect-virt" <<'EOF'
#!/bin/sh
printf 'kvm\n'
EOF
    cat >"$BATS_TEST_TMPDIR/bin/bats" <<'EOF'
#!/bin/sh
[ "${VAIO_SETUP_TEST_VM:-}" = 1 ]
EOF
    chmod +x "$BATS_TEST_TMPDIR/bin/systemd-detect-virt" "$BATS_TEST_TMPDIR/bin/bats"
    run env VAIO_TEST_VM=1 PATH="$BATS_TEST_TMPDIR/bin:$PATH" "$ROOT/tests/integration/run-vm.sh"
    [ "$status" -eq 0 ]
}
