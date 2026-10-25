#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    FIXTURE="$BATS_TEST_TMPDIR"
    mkdir -p "$FIXTURE/bin" "$FIXTURE/sdk/emulator"
    export PATH="$FIXTURE/bin:$PATH" FIXTURE
    source "$ROOT/lib/virtualization.sh"
}

@test "virtualization diagnostics report CPU, KVM, kvm-ok and emulator checks" {
    cat >"$FIXTURE/bin/kvm-ok" <<'SH'
#!/usr/bin/env bash
echo 'INFO: /dev/kvm exists'
echo 'KVM acceleration can be used'
SH
    cat >"$FIXTURE/sdk/emulator/emulator" <<'SH'
#!/usr/bin/env bash
[[ ${1:-} == -accel-check ]] || exit 2
[[ ${ACCEL_FAIL:-0} == 0 ]] || exit 1
echo 'KVM (version 12) installed and usable.'
SH
    chmod +x "$FIXTURE/bin/kvm-ok" "$FIXTURE/sdk/emulator/emulator"
    run virtualization_check "$FIXTURE/sdk"
    [ "$status" != 0 ]
    [[ "$output" == *'CPU virtualization:'* ]]
    [[ "$output" == *'/dev/kvm:'* ]]
    [[ "$output" == *'kvm-ok:'* ]]
    [[ "$output" == *'emulator -accel-check:'* ]]
}

@test "CPU virtualization flag parser accepts SVM or VMX and rejects missing flags" {
    printf 'flags : fpu svm\n' >"$FIXTURE/cpuinfo"
    run _virtualization_cpu_flag "$FIXTURE/cpuinfo"
    [ "$status" = 0 ]
    printf 'flags : fpu aes\n' >"$FIXTURE/cpuinfo"
    run _virtualization_cpu_flag "$FIXTURE/cpuinfo"
    [ "$status" != 0 ]
}

@test "diagnostics report failed kvm-ok and emulator checks" {
    printf '#!/usr/bin/env bash\nexit 1\n' >"$FIXTURE/bin/kvm-ok"
    chmod +x "$FIXTURE/bin/kvm-ok"
    run virtualization_check "$FIXTURE/sdk"
    [ "$status" != 0 ]
    [[ "$output" == *'kvm-ok: failed'* ]]
    printf '#!/usr/bin/env bash\necho KVM unavailable >&2\nexit 1\n' >"$FIXTURE/sdk/emulator/emulator"
    chmod +x "$FIXTURE/sdk/emulator/emulator"
    run virtualization_check "$FIXTURE/sdk"
    [ "$status" != 0 ]
    [[ "$output" == *'emulator -accel-check: failed'* ]]
}

@test "KVM device helpers distinguish missing device and unavailable permissions" {
    run _virtualization_kvm_device "$FIXTURE/absent"
    [ "$status" != 0 ]
    touch "$FIXTURE/locked-kvm"
    chmod 000 "$FIXTURE/locked-kvm"
    run _virtualization_kvm_accessible "$FIXTURE/locked-kvm"
    [ "$status" != 0 ]
}

@test "x86_64 image helper rejects ARM system image paths" {
    run _virtualization_x86_image "$FIXTURE/sdk" 'system-images/android-35/google_apis/arm64-v8a'
    [ "$status" != 0 ]
    run _virtualization_x86_image "$FIXTURE/sdk" '../../etc/x86_64'
    [ "$status" != 0 ]
}
