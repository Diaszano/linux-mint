# Task 13: Read-only workstation diagnostics

## Implementation

`bin/dev-doctor` reports host, swap, zram, KVM, Mesa, thermal/power, cgroup controllers, Gradle, mise, Android SDK, Docker, and run-manifest status as text or stable JSON. It gathers facts through `lib/preflight.sh`, does not call sudo or APT, and does not write files. KVM reports PASS only when the required virtualization checks pass. Installed zram manager packages are reported even when no zram device is active.

## Final verification

All results below are from the final implementation, including the independent probe-status review fix. Earlier interim counts are intentionally omitted.

- Focused disposable-VM suite: `bats --print-output-on-failure tests/unit/dev_doctor.bats` — **9/9 passed**.
- Full sequential disposable-VM Bats unit suite: **173/173 passed**.
- Python unit suite: `python3 -m unittest discover -s tests/unit -p 'test_*.py'` — **19/19 passed**.
- Full sequential disposable-VM integration suite: `VAIO_TEST_VM=1`, guest hostname `vaio-fe16-test-vm` — **18 total; 14 passed, 4 skipped**. Skips were one Docker case and three Gradle cases because those tools were unavailable.
- Static and data checks passed in the guest: `bash -n lib/preflight.sh bin/dev-doctor`, `shellcheck -S warning lib/preflight.sh bin/dev-doctor`, `shfmt -d -i 2 bin/dev-doctor`, `bin/dev-doctor --json | python3 -m json.tool`, and `sha256sum -c tests/fixtures/legacy.sha256`.
- The planned `tests/integration/run-vm.sh` is absent; the repository's integration Bats files were run directly with `VAIO_TEST_VM=1`.

The review fix ensures failed or invalid power-supply `online` reads report WARN/unknown, temperature PASS requires a numeric Celsius measurement, failed or empty `powerprofilesctl get` warns, and combined thermal/power status cannot PASS when an available component warns. The regression test uses an `online` directory so the open fails even when tests run as root.

## Environment and limits

Verification ran in a disposable Ubuntu 24.04 Noble VM with 4 virtual CPUs and approximately 8 GiB RAM. Android SDK/AVD, Gradle, and accessible KVM were unavailable there, so emulator acceleration, Gradle isolation, and related hardware behavior were not verified. No physical VAIO installation, host configuration, or tuning was performed. Sustained performance, thermal behavior, and hardware-dependent acceptance checks remain for the physical notebook with separate authorization.
