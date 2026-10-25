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


## Independent review fix
- Review found that failed/invalid power-supply `online` reads and informational-only `sensors` output could be reported as healthy. Added tests before the code change. The power-supply failure test uses an `online` directory, which makes opening it fail even when the test process is root; the initial red run failed all three new assertions as expected.
- Power-supply status is now PASS only for valid `0`/`1` readings; failed or unknown reads become WARN. Temperature status requires a numeric Celsius measurement. A failed/empty `powerprofilesctl get` becomes WARN. Combined thermal/power status cannot PASS if an available component is WARN.
- Focused disposable-VM suite: `bats --print-output-on-failure tests/unit/dev_doctor.bats` — 9/9 passed.
- Full sequential disposable-VM Bats unit suite: 173/173 passed. Python manifest suite: `python3 -m unittest discover -s tests/unit -p 'test_*.py'` — 19/19 passed.
- Full sequential integration suite in the disposable VM with `VAIO_TEST_VM=1` and guest hostname `vaio-fe16-test-vm`: 18 tests, exit 0; 14 passed and 4 skipped (one Docker test and three Gradle tests because those tools are absent).
- Static and data checks passed in the guest: `bash -n lib/preflight.sh bin/dev-doctor`, `shellcheck -S warning lib/preflight.sh bin/dev-doctor`, `shfmt -d -i 2 bin/dev-doctor`, `bin/dev-doctor --json | python3 -m json.tool`, and `sha256sum -c tests/fixtures/legacy.sha256`.
- The hostname change and all tests ran inside the disposable VM. No physical VAIO installation, host configuration, or tuning was performed. Hardware-dependent behavior remains unverified.
