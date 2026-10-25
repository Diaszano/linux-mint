# Troubleshooting and recovery

Start with read-only diagnostics. Do not disable fail-closed checks to make a workload start.

```sh
dev-doctor
dev-doctor --json
./setup.sh --check
dev-profile show
dev-rollback --list
```

## Setup stops during checks or preview

- Confirm the host is a supported Linux Mint 22.x / Ubuntu Noble x86_64 system and run setup from a normal logged-in user, not as root.
- Read the full conflict and inventory report. If package, swap, service, or systemd unit state is unknown, setup stops before package installation or service configuration. Restore reliable package/service queries and rerun `--check`.
- Existing zram managers, active zram, swap policies, OOM daemons, Docker provider packages/services, or conflicting systemd units are preserved. Do not remove or disable them to force a plan through. Resolve the conflict manually only after reviewing the existing configuration and obtaining explicit authorization for that migration.
- `--check` is read-only. `--dry-run` simulates package changes and previews selected modules. `--yes` confirms the exact plan but does not select optional modules. Repeat the same selection for the actual run after reviewing its preview.
- `--earlyoom` fails before preflight or journaling and returns an unsupported-feature error. No host changes are made. Constrained-build kill priority is unverified; leave it disabled and use `dev-build` for cgroup-limited builds.

## Workload refuses to start

`dev-run` intentionally refuses the workload if it cannot verify the active systemd user scope, process membership, or effective cgroup v2 controls. Check the systemd user manager, cgroup v2 mount, delegated `cpu`, `memory`, and `pids` controllers, and the relevant scope files. Use `dev-doctor --json` to capture a read-only report. Do not set `DEV_LIMITS_DISABLED=1` except for a knowingly unbounded diagnostic command; it bypasses CPU, RAM, swap, and task limits and must never be treated as a successful validation.

The selected profile values are provisional. A low-RAM host may scale the values down, and the emulator wrapper refuses if the adapted cap cannot support its 3 GiB guest configuration. Select the supported `balanced` profile with `dev-profile select balanced` only if the profile choice is malformed or missing; this affects future starts, not running scopes.

If a process is killed at a memory or swap ceiling, record the run ID and inspect the scope's `memory.events`, `memory.swap.events`, and system journal before retrying. Do not disable host swap or increase limits without an authorized, measured calibration.

## Gradle process outside the cgroup

Use the project wrapper through `dev-build` and pass `--no-daemon`:

```sh
dev-build ./gradlew assembleDebug --no-daemon
```

Gradle may use a temporary single-use daemon with `--no-daemon`; that process and its workers must remain in the wrapper's cgroup for the scope guarantee. A previously reused daemon cannot be moved into the scope. Stop existing daemons with the project wrapper's `./gradlew --stop`, then retry the supported recipe. Builds launched directly by Android Studio and detached or externally managed processes are outside the generic wrapper guarantee. Check `/proc/PID/cgroup` and the scope's `cgroup.procs` when diagnosing membership. Do not edit global `~/.gradle/gradle.properties` as a workaround; prefer project-level settings and inspect [Gradle guidance](GRADLE.md).

## Android Emulator or KVM failure

`dev-emulator --list` checks available AVD names without launching. Launch requires an installed x86_64 system image, a readable/writable `/dev/kvm`, successful KVM/accelerator checks, and the wrapper's forced `-accel on`. For missing `/dev/kvm`, check firmware SVM, the distribution KVM packages, user group membership, and whether a new login session applied permission changes. Do not claim KVM acceleration from device access alone; confirm emulator accelerator status and that the process is in the emulator cgroup.

GPU mode is `auto` unless explicitly set. If graphics compatibility is the issue, retry with `-gpu swiftshader`; do not pass flags that disable acceleration or override guest memory/CPU limits.

## mise verification failure

The pinned release is verified with `minisign` using the public key in `config/mise-release.conf`, then its artifact checksum is checked against the signed upstream checksum file. A missing tool, invalid signature, missing or duplicate checksum, version mismatch, or download failure prevents installation. Preserve the diagnostic and retry only after network, repository, and trust configuration are understood. Manual installation must use the same official pinned release, public key, signed checksum manifest, and hash verification. Never run the legacy unverified bootstrap or another downloaded script.

## Docker limits or provider conflict

Docker is optional and not installed by default. The setup preserves an existing Docker provider and refuses conflicting provider dependencies or unknown service state. Do not switch between distro Docker and Docker CE automatically. Rootless Docker requires systemd cgroup v2 delegation; if `dev-doctor` reports ineffective or unknown controllers, treat container limits as unverified. Docker containers are not automatically inside a `dev-run` cgroup. Inspect the effective container cgroup and Compose limits before relying on resource boundaries.

## Safe rollback and interrupted installation

List run IDs and preview before applying any rollback:

```sh
dev-rollback --list
dev-rollback RUN_ID --dry-run
dev-rollback RUN_ID --yes
```

The manifest and backups are under `${XDG_STATE_HOME:-$HOME/.local/state}/vaio-fe16-dev-setup/runs/RUN_ID`. Do not delete this directory until recovery is complete. The ID consists of a 20-digit timestamp and 16 lowercase hexadecimal characters separated by a hyphen. `--dry-run` does not write state; `--yes` applies checksum-safe owned-file and recorded service rollback without prompting.

If a file checksum differs from the journaled post-install checksum, rollback leaves it untouched and reports the conflict. Preserve the edited file, backup, and journal; compare them manually and restore only the intended content. Package removal is a manual review item because dependencies may be shared or ownership uncertain. Review installed package state with the package manager before removing anything. Package upgrades and user data are not guaranteed to be restored.

If installation was interrupted, first run `dev-doctor` and `dev-rollback --list`, then inspect the manifest and its latest intent/applied events. Preview rollback and resolve checksum conflicts manually before retrying setup. Re-run `--check` and `--dry-run`; do not assume an interrupted APT operation or service action completed atomically. Idempotency prevents many duplicate changes, but it does not replace review of a partially completed transaction.

## Physical acceptance
The checklist at `tests/acceptance/vaio-checklist.md` is a blank record, not evidence that the physical VAIO was tested. Do not run setup, change host settings, or start its concurrent workload without separate explicit authorization. Keep the initial memory and swap ceilings provisional; earlyoom remains unavailable and setup fails closed because build-first kill priority is not yet verified. Record missing hardware or prerequisites as `NOT INSTALLED` and investigate any cgroup, swap-exhaustion, KVM, or rollback failure before continuing.
