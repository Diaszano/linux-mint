# Task 7 report: opt-in memory policy

**Status: Partial.** Zram and swappiness safeguards are implemented. Earlyoom remains fail-closed pending a tested way to prefer constrained build workloads over the interactive desktop.

Implemented `memory_plan` and token-confirmed `memory_apply` for zram and swappiness. Default planning is read-only. Plans reject unknown inventory and conflicting managers; zram is pinned to the reviewed Noble package version, LZ4, 50% of logical RAM, and priority 100. Swappiness requires an active zram device with a parseable swap priority. The swap parser accepts both four-field output and the five-field form that includes `USED`.

`setup.sh` sources the memory module and previews explicitly selected memory flags without applying changes. `memory_apply` repeats inventory and conflict checks, audits the user-owned run journal, runtime-masks only the selected new unit before APT, configures zram while masked, then enables, starts, and verifies the service and swap. It does not use global `policy-rc.d`. The privileged file helper is restricted to three fixed memory config paths; backup creation is constrained to the run's private backup directory and preserves original file metadata. Rollback refuses preview and apply after zram activation may have begun, and reports manual recovery without stopping the service or swapping off the device.

An independent review found that earlyoom lacked an explicit reviewed configuration and swappiness did not detect competing sysctl assignments. A reviewed earlyoom configuration was added, but a second review correctly found that a global earlyoom daemon cannot reliably distinguish a constrained build from Android Studio or another desktop process. Earlyoom is therefore unavailable: planning explains the reason, setup preview does not promise installation, and both `memory_apply` and `apt_apply` refuse to install it. No earlyoom policy is enabled. Re-enabling it requires a tested build-first kill-priority mechanism that does not rely on ambiguous process names. Planning and apply scan sysctl configuration directories plus `/etc/sysctl.conf`, reject external `vm.swappiness` assignments, and repeat the check immediately before writing or applying the setting.

The VM initially lacked its matching zram module. I installed `linux-modules-extra-6.8.0-147-generic` in the disposable Noble guest and verified the full apply path. The service became active and enabled; `/etc/default/zramswap` contained the approved values; `swapon` showed `/dev/zram0` at priority 100; `zramctl` reported LZ4 and a 4,163,465,216-byte device, approximately half of the guest's 8,331,026,432-byte logical RAM. Applying rollback to the run printed manual recovery and left both the active service and swap device intact.

Verification in the disposable Noble VM:

- Initial Task 7 run: `bats tests/unit tests/integration`: 118 tests passed; Python unit suite: 15 passed.
- Independent-review fix run: `bats tests/unit tests/integration`: 122 tests passed; Python unit suite: 15 passed. Focused `bats tests/unit/memory.bats`: 16 tests passed, including planning and apply-time sysctl conflict checks.
- Earlyoom priority guard run: focused memory, package, and setup CLI suites passed 51/51. The full suite passed 123/123 Bats tests; Python unit suite passed 15/15. Tests assert that neither memory nor generic package apply reaches APT/systemd for earlyoom, and setup preview does not promise an earlyoom package install.
- After real zram activation, the focused package and memory rerun passed 44 tests.
- `bash -n setup.sh lib/memory.sh lib/packages.sh lib/rollback.sh` passed.
- `bash -n lib/memory.sh lib/packages.sh setup.sh` passed after the earlyoom guard.
- `shfmt -d -i 2 lib/memory.sh` produced no diff.
- `shellcheck -S warning lib/memory.sh lib/packages.sh setup.sh` passed.
- `python3 -m py_compile lib/memory_file.py` passed.
- `shfmt -d -i 2 lib/memory.sh` and `shfmt -d -i 4 lib/rollback.sh` produced no diff.
- `sha256sum -c tests/fixtures/legacy.sha256` passed.
- ShellCheck reported no warnings; it emitted informational notices about dynamic `source` paths and boolean idioms.
- Earlyoom installation is deliberately blocked pending build-first process priority. Package conflict detection also correctly refused earlyoom in the VM because `systemd-oomd` was present; the service was not installed or started.

The guest was left with the explicitly selected zram service active. No `swapoff` or active-zram stop was run.
