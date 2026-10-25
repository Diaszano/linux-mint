#!/usr/bin/env bats

setup() {
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    FIXTURE="$BATS_TEST_TMPDIR"
    PROJECT="$FIXTURE/project"
    SDK="$FIXTURE/sdk"
    AVD_HOME="$FIXTURE/avd"
    mkdir -p "$FIXTURE/bin" "$PROJECT/bin" "$PROJECT/lib" "$SDK/emulator" \
        "$SDK/system-images/android-35/google_apis/x86_64" "$AVD_HOME/Test_x86.avd"
    [[ ! -f "$ROOT/bin/dev-emulator" ]] || cp "$ROOT/bin/dev-emulator" "$PROJECT/bin/dev-emulator"
    [[ ! -f "$ROOT/lib/virtualization.sh" ]] || cp "$ROOT/lib/virtualization.sh" "$PROJECT/lib/virtualization.sh"
    cat >"$PROJECT/bin/dev-run" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$FIXTURE/dev-run.args"
SH
    chmod +x "$PROJECT/bin/dev-run"
    cat >"$SDK/emulator/emulator" <<'SH'
#!/usr/bin/env bash
printf '%s\0' "$@" >>"$FIXTURE/emulator.args"
case ${1:-} in
    -list-avds) printf '%s\n' 'Test_x86' ;;
    -accel-check) [[ ${ACCEL_FAIL:-0} == 0 ]] || exit 1; echo 'KVM (version 12) installed and usable.' ;;
    *) exit 0 ;;
esac
SH
    chmod +x "$SDK/emulator/emulator"
    cat >"$FIXTURE/bin/kvm-ok" <<'SH'
#!/usr/bin/env bash
[[ ${KVM_OK_FAIL:-0} == 0 ]]
SH
    chmod +x "$FIXTURE/bin/kvm-ok"
    cat >"$AVD_HOME/Test_x86.ini" <<EOF
path=$AVD_HOME/Test_x86.avd
EOF
    cat >"$AVD_HOME/Test_x86.avd/config.ini" <<'EOF'
image.sysdir.1=system-images/android-35/google_apis/x86_64/
EOF
    export FIXTURE PROJECT SDK AVD_HOME
    export ANDROID_SDK_ROOT="$SDK" ANDROID_AVD_HOME="$AVD_HOME"
    export PATH="$FIXTURE/bin:$PATH"
    chmod -R a+rX "$FIXTURE"
    cat >"$PROJECT/bin/test-dev-emulator" <<SH
#!/usr/bin/env bash
source "$PROJECT/bin/dev-emulator"
_virtualization_cpu_flag() { return 0; }
_virtualization_kvm_device() { return 0; }
_virtualization_kvm_accessible() { return 0; }
dev_emulator_main "\$@"
SH
    chmod +x "$PROJECT/bin/test-dev-emulator"
}

run_emulator() {
    "$PROJECT/bin/test-dev-emulator" "$@"
}

@test "dev-emulator --list only lists available AVDs" {
    before=$(sha256sum "$AVD_HOME/Test_x86.avd/config.ini")
    run "$PROJECT/bin/dev-emulator" --list
    [ "$status" = 0 ]
    [[ "$output" == *Test_x86* ]]
    [ ! -e "$FIXTURE/dev-run.args" ]
    [ "$(sha256sum "$AVD_HOME/Test_x86.avd/config.ini")" = "$before" ]
}

@test "missing emulator SDK and AVD stop before dev-run" {
    run env ANDROID_SDK_ROOT="$FIXTURE/no-sdk" "$PROJECT/bin/dev-emulator" Test_x86
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/dev-run.args" ]
    run run_emulator Missing
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/dev-run.args" ]
}

@test "inaccessible KVM refuses launch before dev-run" {
    run env ANDROID_SDK_ROOT="$SDK" ANDROID_AVD_HOME="$AVD_HOME" \
        "$PROJECT/bin/dev-emulator" Test_x86
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/dev-run.args" ]
}

@test "failed emulator acceleration check refuses launch before dev-run" {
    ACCEL_FAIL=1 run run_emulator Test_x86
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/dev-run.args" ]
}

@test "failed kvm-ok diagnostic refuses launch before dev-run" {
    KVM_OK_FAIL=1 run run_emulator Test_x86
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/dev-run.args" ]
}

@test "ARM-only AVD is rejected before dev-run" {
    sed -i 's@x86_64@arm64-v8a@' "$AVD_HOME/Test_x86.avd/config.ini"
    run run_emulator Test_x86
    [ "$status" != 0 ]
    [ ! -e "$FIXTURE/dev-run.args" ]
}

@test "acceleration and required-resource overrides are rejected" {
    for arg in -accel -accel=off -no-accel -memory -memory=1024 -cores -cores=2 -avd -avd=Other -no-boot-anim -qemu @Other -gpu=host; do
        run run_emulator Test_x86 "$arg"
        [ "$status" != 0 ]
        [ ! -e "$FIXTURE/dev-run.args" ]
    done
}

@test "x86 AVD launches with forced acceleration and allows software GPU fallback" {
    before=$(sha256sum "$AVD_HOME/Test_x86.avd/config.ini")
    run run_emulator Test_x86 -gpu swiftshader -no-snapshot 'arg with spaces'
    [ "$status" = 0 ]
    mapfile -d '' -t args <"$FIXTURE/dev-run.args"
    [ "${args[0]}" = emulator ]
    [ "${args[1]}" = "$SDK/emulator/emulator" ]
    [[ "${args[*]}" == *'-accel on'* ]]
    [[ "${args[*]}" == *'-memory 3072'* ]]
    [[ "${args[*]}" == *'-cores 4'* ]]
    [[ "${args[*]}" == *'-gpu swiftshader'* ]]
    [[ "${args[*]}" == *'-no-boot-anim'* ]]
    [[ "${args[*]}" == *'arg with spaces'* ]]
    [ "$(sha256sum "$AVD_HOME/Test_x86.avd/config.ini")" = "$before" ]
}

@test "GPU defaults to auto when no fallback is selected" {
    run run_emulator Test_x86
    [ "$status" = 0 ]
    mapfile -d '' -t args <"$FIXTURE/dev-run.args"
    [[ "${args[*]}" == *'-gpu auto'* ]]
}
