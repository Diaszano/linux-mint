#!/usr/bin/env bash
set -Eeuo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)

if [[ ${VAIO_TEST_VM:-} != 1 ]]; then
    printf 'Refusing integration tests: set VAIO_TEST_VM=1 only inside a disposable VM.\n' >&2
    exit 2
fi

if ! command -v systemd-detect-virt >/dev/null 2>&1; then
    printf 'Refusing integration tests: systemd-detect-virt is required.\n' >&2
    exit 2
fi

if ! virtualization=$(systemd-detect-virt --vm); then
    printf 'Refusing integration tests: systemd does not identify this environment as a VM.\n' >&2
    exit 2
fi

if [[ -z $virtualization || $virtualization == none ]]; then
    printf 'Refusing integration tests: virtualization detection returned no VM.\n' >&2
    exit 2
fi

if (($#)); then
    printf 'Usage: VAIO_TEST_VM=1 %s\n' "${BASH_SOURCE[0]}" >&2
    exit 2
fi

command -v bats >/dev/null 2>&1 || {
    printf 'Cannot run VM integration tests: bats is required.\n' >&2
    exit 127
}

printf 'VM integration environment: %s\n' "$virtualization"
export VAIO_SETUP_TEST_VM=1
exec bats --tap "$ROOT"/tests/integration/*.bats
