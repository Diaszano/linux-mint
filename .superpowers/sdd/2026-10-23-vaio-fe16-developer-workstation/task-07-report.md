# Task 7 report: opt-in memory policy

Implemented `memory_plan` and token-confirmed `memory_apply` for zram, earlyoom, and swappiness. Default planning is read-only. Plans reject unknown inventory and conflicting managers; zram is pinned to the reviewed Noble package version, LZ4, 50% of logical RAM, and priority 100. Swappiness requires an active zram device with a parseable swap priority. The swap parser accepts both four-field output and the five-field form that includes `USED`.

`setup.sh` sources the memory module and previews explicitly selected memory flags without applying changes. `memory_apply` repeats inventory and conflict checks, audits the user-owned run journal, runtime-masks only the selected new unit before APT, configures zram while masked, then enables, starts, and verifies the service and swap. It does not use global `policy-rc.d`. The privileged file helper is restricted to three fixed memory config paths; backup creation is constrained to the run's private backup directory and preserves original file metadata. Rollback refuses preview and apply after zram activation may have begun, and reports manual recovery without stopping the service or swapping off the device.

An independent review found that earlyoom lacked an explicit reviewed configuration and swappiness did not detect competing sysctl assignments. The review fixes preview and journal `EARLYOOM_ARGS="-m 10,5 -s 10,5"` before starting earlyoom. This sets 10% SIGTERM and 5% SIGKILL thresholds for both available memory and free swap; earlyoom acts only when both resources are below their threshold and may terminate the largest application. Its package unit was verified from the signed Noble package archive to use `/etc/default/earlyoom` as its environment file. Planning and apply now scan the effective sysctl configuration directories plus `/etc/sysctl.conf`, reject any external `vm.swappiness` assignment, and repeat the check immediately before writing or applying the setting.

The VM initially lacked its matching zram module. I installed `linux-modules-extra-6.8.0-147-generic` in the disposable Noble guest and verified the full apply path. The service became active and enabled; `/etc/default/zramswap` contained the approved values; `swapon` showed `/dev/zram0` at priority 100; `zramctl` reported LZ4 and a 4,163,465,216-byte device, approximately half of the guest's 8,331,026,432-byte logical RAM. Applying rollback to the run printed manual recovery and left both the active service and swap device intact.

Verification in the disposable Noble VM:

- Initial Task 7 run: `bats tests/unit tests/integration`: 118 tests passed; Python unit suite: 15 passed.
- Independent-review fix run: `bats tests/unit tests/integration`: 122 tests passed; Python unit suite: 15 passed. Focused `bats tests/unit/memory.bats`: 16 tests passed, including planning and apply-time sysctl conflict checks.
- After real zram activation, the focused package and memory rerun passed 44 tests.
- `bash -n setup.sh lib/memory.sh lib/packages.sh lib/rollback.sh` passed.
- `python3 -m py_compile lib/memory_file.py` passed.
- `shfmt -d -i 2 lib/memory.sh` and `shfmt -d -i 4 lib/rollback.sh` produced no diff.
- `sha256sum -c tests/fixtures/legacy.sha256` passed.
- ShellCheck reported no warnings; it emitted informational notices about dynamic `source` paths and boolean idioms.
- Earlyoom installation was not exercised: the disposable guest has an existing `systemd-oomd` manager, and the real preflight correctly refused before APT. The Noble package archive, default config path, and service `EnvironmentFile` were inspected without installing or starting earlyoom.

The guest was left with the explicitly selected zram service active. No `swapoff` or active-zram stop was run.
