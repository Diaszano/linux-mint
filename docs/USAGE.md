# Workstation usage

## Scope and prerequisites

The v2 setup targets Linux Mint 22.x on Ubuntu Noble, x86_64. Hardware-specific defaults target a VAIO FE16 with an AMD Ryzen 7 5825U, 16 logical threads, and 24 GiB RAM. The installer must be run as a logged-in, non-root user. It uses `sudo` for selected system package and service operations and requests confirmation before applying the reviewed plan. Do not run it on the physical notebook without separate authorization.

The scripts in [`legacy/vaio-fe16-dev-setup/`](../legacy/vaio-fe16-dev-setup/) document the recovered v1 behavior. They are retained unchanged for characterization and must not be used as the v2 setup entry point.

## Check, preview, selection, and confirmation

```sh
./setup.sh --help
./setup.sh --check
./setup.sh --dry-run
```

`--check` gathers host and conflict information without installing packages, changing services, or writing setup state. `--dry-run` runs package simulations and displays the selected modules and intended operations without applying them. A package or service inventory that cannot be established, or a conflicting memory manager or systemd unit, blocks the relevant plan before APT or service changes.

The default modules are `baseline`, `kvm`, `mise`, and `wrappers`. `--yes` confirms only the exact plan that was previewed; it does not select optional modules. To restrict the plan, use `--only` with a comma-separated module list. `--skip` excludes listed modules. Selecting and skipping the same module is an error. For example:

```sh
./setup.sh --dry-run --only baseline,kvm,mise,wrappers
./setup.sh --only baseline,kvm,mise,wrappers --yes
```

The options exposed by `setup.sh --help` are:

| Option | Effect |
| --- | --- |
| `--check` | Read-only host, hardware, package, swap, and service checks. |
| `--dry-run` | Simulate and show selected operations without applying them. |
| `--only LIST` | Select only comma-separated modules. |
| `--skip LIST` | Exclude comma-separated modules. |
| `--zram` | Explicitly select the zram module; existing swap/zram conflicts stop it. |
| `--docker` | Explicitly select Docker; an existing provider/service is preserved. |
| `--earlyoom` | Select the earlyoom module; currently unavailable and fails closed. |
| `--gradle-global` | Explicitly request the optional user-level Gradle properties block. |
| `--swappiness VALUE` | Explicitly request a swappiness value from 0 through 200; requires compatible active zram. |
| `--skip-mise` | Exclude mise from the default selection. |
| `--no-docker` | Alias for `--skip docker`. |
| `--no-earlyoom` | Alias for `--skip earlyoom`. |
| `--yes` | Confirm the displayed plan without the interactive confirmation prompt. |

## Default-off modules and conflicts

Docker, new zram, earlyoom, user-wide Gradle settings, and swappiness/sysctl changes are off by default. Existing swap, zram, OOM policy, Docker provider, Docker services, and user Gradle settings are preserved unless an explicitly selected module is eligible and its conflict checks pass. Docker provider conflicts (including distro Docker versus Docker CE) are checked before package operations. Existing or unrecognized services are not silently replaced.

The `--earlyoom` option returns an unsupported-feature error before preflight, journaling, package, or service operations. It makes no host changes. Constrained-build kill priority is unverified, so leave it disabled and use `dev-build` for cgroup-limited builds.

The zram module rejects existing zram devices, swap managers/configuration, conflicting units, indeterminate swap state, or incompatible swap priority. The swappiness module requires active compatible zram and rejects an existing conflicting `vm.swappiness` policy. Neither module disables or replaces existing swap or zram automatically.

## KVM and Android Emulator

Install and configure Android Studio and the Android SDK through their supported user-facing setup. Create an x86_64 AVD using an installed x86_64 system image. Enable CPU virtualization (SVM) in firmware when required and ensure the logged-in user can access `/dev/kvm` using the distribution's supported KVM group or permissions. Log out and back in after group changes. The workstation setup checks KVM packages and device readiness but does not change firmware settings.

Check health and list AVDs without launching one:

```sh
dev-doctor
dev-emulator --list
```

Launch by AVD name:

```sh
dev-emulator My_Phone_API_35
```

The wrapper requires a compatible x86_64 AVD, successful KVM checks, and forces `-accel on`; it refuses acceleration-disabling arguments. The emulator is placed in its own workload cgroup with independent CPU, memory, swap, and task ceilings, regardless of the AVD's guest settings. GPU rendering defaults to `auto`. If graphics compatibility problems occur, try `dev-emulator My_Phone_API_35 -gpu swiftshader`. This changes the rendering backend only; acceleration remains required.

## Workload isolation and Gradle

Use the project Gradle wrapper with `--no-daemon`:

```sh
dev-build ./gradlew assembleDebug --no-daemon
```

Gradle's `--no-daemon` disables reuse of a persistent Gradle daemon, but Gradle may create a temporary single-use daemon to honor JVM settings. The build gate verifies that the started process and descendants, including this temporary daemon, compiler processes, and Gradle workers, remain inside the build cgroup. A previously running daemon cannot be moved into that cgroup and is outside the guarantee. Generic commands passed to `dev-build` may spawn detached or externally managed processes; only descendants that remain in the inherited cgroup are covered.

Builds started directly from Android Studio do not pass through `dev-build` and are outside its cgroup guarantee. The IDE itself also has its own memory use. For project-specific Gradle tuning, prefer project-level `gradle.properties` and validate the project before changing build concurrency or caches. `--gradle-global` is explicit, opt-in, user-wide configuration and may affect other projects; it is not required for the supported isolated recipe. See [Gradle guidance](GRADLE.md).

`dev-run` supports `build`, `emulator`, and `heavy` profiles. Initial balanced CPU/RAM/swap/task ceilings are provisional and adapt downward on smaller hosts. `dev-profile show` displays the table and `dev-profile select balanced` records the supported user profile for future launches. Profile selection does not modify currently running scopes. `DEV_LIMITS_DISABLED=1` bypasses all resource limits and must be treated as unsafe troubleshooting only.

## Docker

Docker installation is opt-in with `--docker`. Existing Docker installations are preserved. Docker containers are separate workloads and are not automatically children of a `dev-run` cgroup. For rootless Docker, verify cgroup v2 systemd delegation for CPU, memory, and PIDs; otherwise Docker's per-container resource limits may be ineffective. The example Compose file is explicitly invoked by the user, binds services to loopback, and requires a password from the environment:

```sh
docker compose -f examples/compose-limits.example.yaml up -d
```

Review the Compose file and confirm Docker's effective limits for the installed rootless or rootful configuration before running services.

## mise authenticity and installation

The setup pins mise release `v2026.10.18` and the x86-64 Linux asset in [`config/mise-release.conf`](../config/mise-release.conf). It obtains the release asset, `SHASUMS256.txt`, and detached signature over HTTPS. The pinned minisign public key is:

```text
RWTC3g8W3z4RZK3V3qv7fa1QY4JEWyBtqIHW+85QlJpZc5yG+uNYNBSZ
```

The installer verifies `SHASUMS256.txt.minisig` against that key with `minisign`, verifies the pinned asset's SHA-256 against the signed checksum list, checks the binary's reported version, and only then installs it. `minisign` is supplied by the configured distribution package repository when needed. If signature, checksum, version, or download verification fails, setup fails without installing the artifact. For manual installation, use only the official pinned upstream release and independently verify its signed checksum manifest with this key before installing; never execute an unverified bootstrap script.

An existing executable mise binary is reused and is not overwritten. Shell initialization adds an owned PATH block so the installed `~/.local/bin/mise` is available in Bash and, when present, Zsh.

## User wrappers and audit records

The `wrappers` module installs user-owned launchers into `~/.local/bin` and adds a marked PATH block to owned shell startup files. It does not modify system-wide PATH files. Start a new shell or source the relevant startup file after installation. The wrapper scripts in the repository's `bin/` directory can also be inspected and invoked directly.

Each setup run records a run ID and JSONL manifest under `${XDG_STATE_HOME:-$HOME/.local/state}/vaio-fe16-dev-setup/runs/`. Use the installed rollback tool to list runs and inspect a proposed reversal:

```sh
dev-rollback --list
dev-rollback RUN_ID --dry-run
dev-rollback RUN_ID
dev-rollback RUN_ID --yes
```

The run ID format is a 20-digit timestamp, hyphen, and 16 lowercase hexadecimal characters. The default rollback command previews and asks for confirmation; `--dry-run` only previews and `--yes` applies the previewed rollback without prompting. File rollback restores an owned file only when its current checksum still matches the checksum recorded after installation. If it has changed, rollback reports the conflict and leaves the file untouched. Review the exact run manifest and preview before applying a rollback.

| Persistent module | Recorded rollback behavior |
| --- | --- |
| `baseline` | Journaled package changes are listed for manual review; package removal is never automatic. |
| `kvm` | Journaled package changes are listed for manual review; package removal is never automatic. |
| `mise` | The owned installed binary and shell startup changes are eligible for checksum-safe rollback; package changes remain manual review. |
| `wrappers` | Owned launchers and marked shell PATH blocks are restored or removed only if their current checksums still match. |
| `zram` | Owned configuration and recorded service state are previewed for safe reversal; package removal is a manual review item. |
| `docker` | Recorded service state is safely reviewed; package removal is a manual review item and existing Docker is preserved. |
| `gradle-global` | The user Gradle properties file is restored only if the managed post-install content still matches its recorded checksum. |
| `swappiness` | The owned sysctl file is checksum-checked; runtime restoration is shown and must be reviewed against current policy. |
| `earlyoom` | No persistent change is made because the module is unavailable and fails closed. |

Package removal is not automatic: dependency ownership may be shared or uncertain. The rollback preview identifies package changes for manual review. Package upgrades and user data are not promised reversible. Service and owned-file rollback are limited to journaled changes and safe before/after state checks. Preserve the manifest and backups until recovery is complete.

## Version and health diagnostics

```sh
dev-doctor
dev-doctor --json
dev-profile show
dev-rollback --list
```

`dev-doctor` is read-only and distinguishes missing or untested components from a passing check. It reports host, swap/zram, KVM, cgroup, Android SDK, Gradle, mise, Docker, thermal/power, and manifest information when available. See [Troubleshooting](TROUBLESHOOTING.md) when a check is missing or fails.
