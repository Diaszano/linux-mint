# Task 13: Read-only workstation diagnostics

## Implementation

Added `bin/dev-doctor` with text and stable JSON output for host, swap, zram, KVM, Mesa, thermal/power, cgroup controllers, Gradle, mise, Android SDK, Docker, and run manifest. It gathers diagnostics through `lib/preflight.sh`, reads existing sysctls and package/tool state, and does not call sudo/APT or write files. The KVM result includes a manual remediation step and does not report PASS unless CPU virtualization, `/dev/kvm` access, `kvm-ok`, and the emulator acceleration probe all pass. Installed zram manager packages are reported even when no zram device is active.

## TDD and verification

- The initial missing-command test run failed as expected. A further regression test failed when an installed `zram-tools` manager with no active device was incorrectly reported as `NOT INSTALLED`; the implementation now reports `WARN` and identifies the package.
- Focused disposable-VM suite: `tests/unit/dev_doctor.bats` passed 6/6.
- Disposable-VM static checks passed: `bash -n bin/dev-doctor lib/preflight.sh`, `shellcheck -S warning bin/dev-doctor lib/preflight.sh`, `shfmt -d -i 2 bin/dev-doctor`, and `bin/dev-doctor --json | python3 -m json.tool`.
- Full sequential disposable-VM unit suite: 170 Bats tests passed; `python3 tests/unit/test_manifest.py` passed 19 tests.
- Full sequential disposable-VM integration suite: 18 tests reported, 15 passed and 3 Gradle tests skipped because Gradle is not installed in this clean overlay guest. The three skipped cases are single-use daemon containment, reusable-daemon isolation, and observer-failure cleanup.
- The plan names `tests/integration/run-vm.sh`, but that runner does not exist in the repository. The actual integration Bats files were executed directly with `VAIO_TEST_VM=1` in the disposable guest.

## Environment and limits

The disposable guest identifies as Ubuntu 24.04 Noble, with 4 virtual CPUs and approximately 8 GiB RAM. It does not have an Android SDK/AVD, Gradle, or accessible KVM device; `dev-doctor` correctly reports KVM `FAIL` with manual steps, Android SDK and Gradle `NOT INSTALLED`, Docker engine `WARN` because the daemon is unavailable, and unsupported Mint host `WARN`. These results do not verify Android Emulator acceleration, Gradle isolation, physical VAIO hardware behavior, sustained performance, or thermal behavior. No installation, host tuning, or physical notebook changes were performed.

`shfmt` passes on the new executable. Applying `shfmt` to all of `lib/preflight.sh` reports formatting differences across pre-existing code, so that broad unrelated formatting change was not applied.
