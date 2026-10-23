# Design review decisions — 2026-10-23

**Status:** The owner approved these revisions to the proposed design. Final design approval, implementation planning, installation and host tuning remain pending. No target machine was modified.

The v1 behavior baseline is the supplied source at `legacy/vaio-fe16-dev-setup/`. It contains `setup.sh`, four `bin/dev-*` scripts, a README and a bounded Compose example. Keep that snapshot unchanged. No original ZIP checksum is available in this checkout, so its external provenance is not independently verified.

| Area | V1 behavior | Proposed v2 contract |
| --- | --- | --- |
| Docker | Installed unless `--no-docker` | Off by default; explicit `--docker` |
| earlyoom | Installed unless `--no-earlyoom` | Off by default; inspect existing OOM services before opt-in |
| zram | Installs `zram-tools` and manages `zramswap` | Preserve existing swap/zram; explicit `--zram` only after pre-install conflict checks |
| VM sysctls | Writes swappiness 100 and page-cluster 0 | Preserve both by default; any swappiness experiment requires separate preview |
| Gradle | Always edits user properties | Project-level guidance; global block requires separate opt-in and conflict check |
| Build isolation | Requests cgroup limits | Gate payload until effective CPU, memory, swap and task limits and scope membership are verified |
| Gradle daemon | Example uses `--no-daemon` | Supported isolation recipe requires it and verifies any single-use daemon and workers in the scope |
| Emulator | Checks `/dev/kvm`, uses acceleration default | Require KVM, x86_64 AVD and `-accel on`; GPU `auto` with documented fallback |
| mise | Executes downloaded installer script | Pin official release artifact; verify signed checksum manifest and binary hash before install |
| Rollback | Backups and manual instructions | Manifest, checksummed backups and conservative rollback for owned changes |

Initial 24 GB profile ceilings are build 9 GiB RAM + 2 GiB swap, emulator 6 GiB RAM + 1 GiB swap, and other heavy work 8 GiB RAM + 2 GiB swap. These are independent workload limits, not a machine-wide reservation. Adjust only after repeated VAIO measurements of memory, swap, PSI, thermals and desktop latency.

The design and this record describe **proposed v2 behavior**. The unchanged legacy README describes v1 only. The root README is a design handoff until v2 exists. Idempotence, interruption and rollback tests must pass in a disposable VM before any host tuning. Hardware acceptance includes Android Studio, one accelerated emulator, a scoped Gradle build and optional bounded Docker services.

Approving the final design will authorize `superpowers:writing-plans` only. It will not authorize running an installer or changing host settings.
