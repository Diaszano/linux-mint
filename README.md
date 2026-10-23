# VAIO FE16 Developer Workstation — Superpowers design review

**State: revised design draft awaiting final approval; no v2 implementation exists.**

This repository handoff is for reviewing and planning the next generation of a
Linux Mint development workstation setup for a Ryzen 7 5825U with 24 GiB RAM.
Do **not** execute `legacy/vaio-fe16-dev-setup/setup.sh` expecting the new v2
behavior. It is retained unmodified for inspection and characterization tests.

## Read these files first

- `docs/superpowers/specs/2026-10-23-vaio-fe16-developer-workstation-design.md`:
  authoritative **proposed** v2 behavior and acceptance criteria.
- `REVIEW-DECISIONS.md`: resolution of all five review comments and evidence.
- `legacy/vaio-fe16-dev-setup/`: recovered implementation snapshot from an
  earlier chat; its `README.md` describes the historical v1 behavior.

## Important distinction: v1 versus proposed v2

| Area | Recovered v1 scripts | Proposed v2 default |
| --- | --- | --- |
| Docker | Installed unless `--no-docker` | Not installed unless `--docker` |
| earlyoom | Installed unless `--no-earlyoom` | Not installed unless `--earlyoom`, conflicts checked |
| zram | `zram-tools` installed and configured during setup | Existing swap/zram preserved; new zram requires explicit `--zram` approval after conflict checks |
| Gradle properties | Always edits user `~/.gradle/gradle.properties` | No global edit; optional `--gradle-global` after separate consent |
| Memory sysctls | Writes swappiness 100 and page-cluster 0 | Leaves both untouched by default |
| systemd resource limits | Requests limits from systemd | Blocks payload until CPU, memory, swap and task limits are verified in the kernel cgroup |
| Android Emulator | Checks `/dev/kvm` access, then launches with automatic acceleration | Requires a compatible x86_64 AVD and `-accel on`; GPU defaults to `auto` |
| mise | Downloads and executes an unverified installer | Uses a pinned upstream release artifact with signed checksum verification |
| Rollback | Backups and manual instructions | Run manifest, checksummed backups and safe rollback |

## Intended v2 contract, AFTER implementation and approval

`setup.sh --check` and `setup.sh --dry-run` will be read-only. Default installation
requires an explicit confirmation and will not change zram, Docker, earlyoom,
global Gradle configuration or VM sysctls. Owned file and service changes will
have audit entries and safe rollback; unrelated package upgrades cannot be
restored automatically. Wrappers will verify per-workload CPU, RAM, swap and
task limits before execution. The supported isolated Gradle recipe uses
`--no-daemon`; builds launched by an existing Android Studio or Gradle daemon
are outside the generic wrapper guarantee.

Do not add instructions promising v2 install functionality until implementation
and host-independent tests pass. Before applying host tuning, test rollback,
idempotence and fail-closed behavior in a disposable VM.
