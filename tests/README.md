# Test evidence and environment boundaries

## Test layers

- `tests/unit/*.bats` uses temporary directories and stub executables to verify CLI behavior, journaling, idempotency, checksum-safe rollback, cgroup gate failures, package/service conflict barriers, mise signature failure behavior, and wrapper contracts. `tests/unit/test_manifest.py` covers manifest validation and rollback data handling.
- `tests/integration/*.bats` inspects live systemd, cgroup v2, package, service, KVM, and workload behavior. These tests may install packages, create resource pressure, or alter VM services. They are allowed only inside a disposable, snapshot-backed virtual machine.
- `tests/acceptance/` records separate physical VAIO FE16 checks. Do not infer physical hardware behavior from a passing VM suite.

## Disposable VM integration gate

The integration runner requires both a deliberate `VAIO_TEST_VM=1` environment setting and a successful `systemd-detect-virt --vm` check. The environment variable alone is insufficient. It refuses to run when either check fails, and runs only the integration Bats files:

```sh
VAIO_TEST_VM=1 bash tests/integration/run-vm.sh
```

After both gates pass, the runner sets `VAIO_SETUP_TEST_VM=1` for the suite so the setup wrapper install/rollback test runs. That test uses a temporary home, stubs the operating system identity, and selects only the user wrapper module; it does not install packages or modify guest system settings. Docker and Gradle installation tests require their own separate opt-ins, which the runner does not set. The runner does not enable those optional installations.

Run the command only in a disposable VM with a snapshot or equivalent recovery point. Before running, verify that the guest is disposable, the snapshot is current, and the repository under test is the intended checkout. The runner does not create or verify a VM snapshot. It must never be used on the physical VAIO FE16 or another host whose configuration must be preserved.

## Existing legacy characterization

`legacy_behavior.bats` characterizes the supplied snapshot by inspecting its files; it does not execute setup or workload scripts. Assertions record observed v1 behavior: Docker and earlyoom default on; setup writes user Gradle properties and `vm.swappiness=100` / `vm.page-cluster=0`; `--check` exits through source-tree `bin/dev-doctor` before APT actions; `dev-run` requests CPUQuota, MemoryHigh, MemoryMax, and TasksMax without reading kernel limit files; `dev-build` forwards `"$@"`; and the legacy Compose example's service limits and loopback-only port binds.

`tests/fixtures/legacy.sha256` hashes regular files in the supplied `legacy/vaio-fe16-dev-setup/` snapshot. No checksum of the original ZIP was supplied, so these hashes identify only the current repository snapshot. The legacy scripts and README remain unchanged.

## Documentation contract

`docs_contract.bats` compares documented options with `setup.sh --help`, checks the rollback and default-off contract, verifies English documentation and legacy README preservation, prevents unsupported performance or IDE/daemon claims, and tests that the VM runner refuses absent opt-in or a non-VM environment.

## Static checks

From the repository root, host-independent static and unit checks are:

```sh
bash -n setup.sh lib/*.sh bin/* tests/integration/run-vm.sh
shfmt -i 2 -d setup.sh
shfmt -i 2 -d lib/backup.sh lib/common.sh lib/gradle.sh lib/memory.sh lib/mise.sh bin/dev-build bin/dev-doctor
shfmt -i 4 -d lib/profiles.sh lib/rollback.sh lib/virtualization.sh bin/dev-emulator bin/dev-gate bin/dev-rollback bin/dev-run tests/integration/run-vm.sh
bash -n tests/integration/run-vm.sh
shellcheck -x -S warning setup.sh tests/integration/run-vm.sh
yamllint examples/compose-limits.example.yaml
bats tests/unit/*.bats
python3 tests/unit/test_manifest.py
sha256sum -c tests/fixtures/legacy.sha256
```

The focused ShellCheck command above covers the setup entrypoint and new runner at warning severity. The full-tree warning-severity gate is `shellcheck -x -S warning setup.sh lib/*.sh bin/* tests/integration/run-vm.sh`; it passes with no warning or error diagnostics. Default full-tree ShellCheck (`shellcheck setup.sh lib/*.sh bin/* tests/integration/run-vm.sh`) exits 1 with 49 informational/style diagnostics, all severity `info`, including five in `setup.sh`; these are advisory and are not reported as a clean default run. See the [Task 17 verification report](../.superpowers/sdd/2026-10-23-vaio-fe16-developer-workstation/task-17-report.md).

The `shfmt` commands above cover files whose established two-space or four-space styles are consistent. The untouched `lib/docker.sh`, `lib/install-wrappers.sh`, `lib/packages.sh`, `lib/preflight.sh`, and `bin/dev-profile` files contain mixed indentation and are excluded rather than mass-reformatted; they remain a style baseline to address separately.

The static/unit commands are not installation tests and do not authorize host configuration changes. A formatting difference in an untouched legacy or previously reviewed file should be reported rather than broadly reformatted as part of a documentation change.
