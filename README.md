# VAIO FE16 Developer Workstation

This repository contains a Linux Mint 22.x workstation setup and scoped workload tools for the VAIO FE16, targeting the Ryzen 7 5825U and 24 GiB RAM. The implementation is conservative: it verifies workload controls before launch, preserves existing memory configuration by default, and records owned changes for review and rollback.

## Start here

- [Usage and installation](docs/USAGE.md)
- [Gradle guidance](docs/GRADLE.md)
- [Performance measurement protocol](docs/PERFORMANCE.md)
- [Troubleshooting and recovery](docs/TROUBLESHOOTING.md)
- [Test evidence and VM safety](tests/README.md)
- [Approved Revision 3 design](docs/superpowers/specs/2026-10-23-vaio-fe16-developer-workstation-design.md)

The original scripts remain unchanged under `legacy/vaio-fe16-dev-setup/` and are prior art, not the v2 entry point. Read their [historical README](legacy/vaio-fe16-dev-setup/README.md) for the old behavior.

## Setup preview

Run `./setup.sh --check` for read-only checks or `./setup.sh --dry-run` to inspect the proposed transaction. Review package, service, file, and conflict details before confirming installation. The default modules are `baseline`, `kvm`, `mise`, and `wrappers`. Docker, zram, earlyoom, global Gradle settings, and swappiness changes are disabled by default. `earlyoom` remains unavailable and fails closed because constrained-build kill priority is unverified.

Supported options are `--check`, `--dry-run`, `--only`, `--skip`, `--zram`, `--docker`, `--earlyoom`, `--gradle-global`, `--swappiness`, `--skip-mise`, `--no-docker`, `--no-earlyoom`, and `--yes`. `setup.sh --help` is authoritative. See [usage](docs/USAGE.md) for the exact selection and confirmation rules.

## Workload tools

The user wrappers are `dev-run`, `dev-build`, `dev-emulator`, `dev-doctor`, `dev-profile`, and `dev-rollback`. `dev-run` starts a command only after verifying its systemd scope, cgroup membership, CPU, memory, swap, and task ceilings. `dev-build` is the supported entry for isolated builds; Android Studio builds and daemons already running elsewhere are outside its scope guarantee. The recommended Gradle invocation is:

```sh
dev-build ./gradlew assembleDebug --no-daemon
```

The emulator wrapper requires a compatible x86_64 AVD and KVM, passes `-accel on`, and uses GPU mode `auto` by default. These controls and known boundaries are documented in [usage](docs/USAGE.md).

## Safety and performance status

All per-workload resource ceilings are provisional until calibrated from representative measurements. No performance improvement is claimed. The proposed measurement workload, baseline procedure, and metrics are in [PERFORMANCE.md](docs/PERFORMANCE.md). Physical VAIO installation and acceptance checks require separate authorization; this repository does not treat VM results as physical-hardware evidence.
