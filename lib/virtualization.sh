#!/usr/bin/env bash

_VIRTUALIZATION_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

_virtualization_cpu_flag() {
    grep -Eiq '(^|[[:space:]])(svm|vmx)([[:space:]]|$)' "$1"
}

_virtualization_kvm_device() {
    [[ -c $1 ]]
}

_virtualization_kvm_accessible() {
    [[ -r $1 && -w $1 ]]
}

_virtualization_x86_image() {
    local sdk=$1 image=${2//;/\/} system_root resolved
    [[ -d $sdk && -n $image ]] || return 1
    system_root=$(realpath -e -- "$sdk/system-images") || return 1
    if [[ $image == /* ]]; then
        resolved=$(realpath -e -- "$image") || return 1
    else
        resolved=$(realpath -e -- "$sdk/$image") || return 1
    fi
    [[ -d $resolved && $resolved == "$system_root"/* && $resolved == */x86_64 ]]
}

_virtualization_sdk() {
    local sdk=${1:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}}
    [[ -n $sdk && -d $sdk ]] || return 1
    realpath -e -- "$sdk"
}

virtualization_check() {
    local sdk=${1:-${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}} emulator='' result=0 output
    if _virtualization_cpu_flag /proc/cpuinfo; then
        printf 'CPU virtualization: available (svm/vmx)\n'
    else
        printf 'CPU virtualization: unavailable (svm/vmx flag missing)\n'
        result=1
    fi
    if _virtualization_kvm_device /dev/kvm; then
        if _virtualization_kvm_accessible /dev/kvm; then
            printf '/dev/kvm: accessible\n'
        else
            printf '/dev/kvm: present but inaccessible\n'
            result=1
        fi
    else
        printf '/dev/kvm: unavailable\n'
        result=1
    fi
    if command -v kvm-ok >/dev/null 2>&1; then
        if output=$(kvm-ok 2>&1); then
            printf 'kvm-ok: available\n'
        else
            printf 'kvm-ok: failed\n%s\n' "$output"
            result=1
        fi
    else
        printf 'kvm-ok: unavailable (optional diagnostic)\n'
    fi
    if [[ -n $sdk && -x $sdk/emulator/emulator ]]; then
        emulator=$sdk/emulator/emulator
    elif command -v emulator >/dev/null 2>&1; then
        emulator=$(command -v emulator)
    fi
    if [[ -n $emulator ]]; then
        if output=$("$emulator" -accel-check 2>&1) && grep -Eqi 'KVM.*installed and usable' <<<"$output"; then
            printf 'emulator -accel-check: KVM installed and usable\n'
        else
            printf 'emulator -accel-check: failed\n%s\n' "$output"
            result=1
        fi
    else
        printf 'emulator -accel-check: unavailable (SDK emulator not found)\n'
        result=1
    fi
    return "$result"
}

virtualization_require_kvm() {
    local sdk=$1 emulator output
    emulator=$sdk/emulator/emulator
    _virtualization_cpu_flag /proc/cpuinfo || {
        printf 'Error: CPU virtualization (SVM/VMX) is unavailable; check firmware settings.\n' >&2
        return 1
    }
    _virtualization_kvm_device /dev/kvm && _virtualization_kvm_accessible /dev/kvm || {
        printf 'Error: /dev/kvm is missing or inaccessible; check KVM installation and user permissions.\n' >&2
        return 1
    }
    if command -v kvm-ok >/dev/null 2>&1 && ! kvm-ok >/dev/null 2>&1; then
        printf 'Error: kvm-ok reports that KVM cannot be used.\n' >&2
        return 1
    fi
    output=$("$emulator" -accel-check 2>&1) || {
        printf 'Error: Android Emulator KVM acceleration check failed.\n%s\n' "$output" >&2
        return 1
    }
    grep -Eqi 'KVM.*installed and usable' <<<"$output" || {
        printf 'Error: Android Emulator did not confirm usable KVM acceleration.\n%s\n' "$output" >&2
        return 1
    }
}
