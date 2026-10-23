# VAIO FE16 Developer Workstation — Design Specification

**Date:** 2026-10-23
**Status:** Revision 3 — design revisions approved for review; implementation pending explicit final approval
**Target:** Linux Mint 22.x Cinnamon, x86_64, AMD Ryzen 7 5825U, 24 GB RAM
**Language conventions:** English code, identifiers, comments and Git history; Brazilian Portuguese for terminal output and user-facing documentation.
**Prior art:** The supplied legacy implementation is present at `legacy/vaio-fe16-dev-setup/`: `setup.sh`, four `bin/dev-*` scripts, `README.md` and `compose-limits.example.yaml`. Treat these files as the behavior baseline and keep them unchanged. An original ZIP checksum is unavailable in this checkout, so independent provenance verification is not claimed. The legacy README documents v1 only, **not the proposed v2 setup contract**.

**Review decisions (proposed):** project-level Gradle guidance by default; no automatic global Gradle edits; OOM protection via scoped cgroups first, earlyoom explicit opt-in; preserve existing swappiness/page-cluster; Docker opt-in; guarded pre-exec cgroup validation; manifest-backed rollback. These are adopted into this revised draft, **not approved for host execution**.

## 1. Intent

Build a reproducible **post-format installation and configuration toolkit** for a Linux Mint development laptop. The toolkit must prioritize **high sustained throughput without sacrificing desktop responsiveness**, particularly when running Android Studio, an accelerated Android Emulator, backend builds and local Docker services concurrently. It must be inspectable, idempotent, modular, minimally invasive and reversible.

The machine is a VAIO FE16 with a Ryzen 7 5825U (8 physical cores / 16 threads, nominal 15 W TDP), 24 GB of RAM and integrated Radeon graphics. The CPU and GPU share the notebook's thermal and memory constraints. Sustained performance cannot be maximized by permanently forcing CPU frequency or by allowing every tool unrestricted concurrency.

**Primary work:** Go, Python, C#/.NET, Node.js/TypeScript, Protocol Buffers and local infrastructure.
**Mobile work:** Native Android with Kotlin, Gradle, Android Studio and KVM-accelerated Android Emulator.
**Tool-version manager:** `mise` is authoritative for programming-language runtimes and tools where supported; honor each project's `mise.toml` / `.tool-versions`.

This is a **design specification**, not an approved implementation plan. Superpowers should move to `writing-plans` **only after this document has been reviewed and approved**.

## 2. Goals, Non-goals and Anti-goals

### Goals

- One entry point, `./setup.sh`, with `--check`, `--dry-run`, selectable components and clear status output; suitable for a clean Mint installation. Default host mutation must be conservative and independently reversible.
- Safe repeated runs: no duplicate shell hooks, duplicate Gradle properties, destructive configuration overwrites, or unintended package-manager conflicts.
- Keep the Cinnamon desktop usable while independent resource-limited commands compile and/or launch an emulator.
- Preserve existing swap and zram by default; offer explicitly approved high-priority zram provisioning while retaining disk swap when present.
- Use **KVM/AMD-V** and Mesa graphics acceleration where supported, with verification and actionable troubleshooting.
- Install baseline development dependencies without imposing unsolicited global language versions; keep `mise` configuration clean.
- Include diagnosis, audit logs, backups, partial-failure recovery and a practical rollback procedure.
- Provide reproducible validation and before/after measurements, rather than promising impossible zero-freeze guarantees.

### Non-goals

- Disk partitioning, formatting, bootloader modification, OS installation or moving/erasing user data.
- Installing all SDKs, Android images or language versions automatically. Android Studio/SDK acceptance and large downloads are opt-in.
- Guaranteeing that every GUI-launched IDE task is enclosed by `dev-run` cgroup limits.
- Overclocking, undervolting, disabling security mitigations, forcing CPU governors, patching kernels or overengineering a desktop deployment.
- Automatic installation of Flutter, React Native, iOS SDKs or all JetBrains IDEs; future optional modules may cover these.
- Replacing project-specific build settings or disabling the Gradle cache indiscriminately.

### Anti-goals

- Making the machine *look* fast by using swap settings that risk data loss or by exhausting all CPU threads.
- Silently running a build without resource limits after a requested limited launch fails.
- Killing the desktop/session merely to rescue an oversized build.
- Deleting another tool's configuration, changing project files, or running a downloaded script without source verification.

## 3. Constraints and Working Assumptions

| Area | Requirement |
| --- | --- |
| OS | Support Linux Mint 22.x (Ubuntu Noble/24.04 package base); reject unsupported platforms with explanations. |
| CPU | Detect actual core/thread count at runtime; optimize defaults for Ryzen 7 5825U, but do not assume every FE16 is identical. |
| Memory | Detect physical RAM rather than hard-coding 24 GB; cap configurations according to actual capacity. |
| Storage | Detect storage type and free capacity; **do not assume NVMe**. Do not alter filesystem or mount options. |
| Privileges | Run as the normal logged-in user; elevate only individual system operations via sudo. |
| Sessions | Bash first; Zsh when present; do not assume users launch IDEs from interactive shells. |
| Framework | Bash with shellcheck/shfmt conventions; external binaries only where justified. |
| Packaging | Distribution packages where suitable; official upstream downloads only when deliberate and verified. |
| Safety | Back up preexisting files; preserve external edits; avoid concurrent OOM daemons and zram managers. |
| Upgrades | Avoid hard pinning unverified versions; record resolved versions in diagnostics. |

## 4. Approaches Considered

**A. Single large Bash script (existing approach).** Few files and simple onboarding, but difficult to test, review or partially reverse. Appropriate for a one-off prototype; insufficient for long-term evolution.

**B. Modular Bash toolkit with declarative profiles (recommended).** Keep a lightweight `setup.sh`, small responsibility-based modules, user-configurable profiles, systemd cgroup wrappers, tests and explicit backups. Fits Mint and existing Bash code; minimal long-term maintenance burden. **Proposed choice; not yet approved.**

**C. Ansible or Nix configuration.** Strong declarative/state benefits at the cost of another system to learn, bootstrap and debug. Revisit only if multiple machines need the same configuration or a fleet-wide deployment is required.

## 5. High-Level Architecture

```text
setup.sh
  -> preflight / hardware detection
  -> read-only package, swap, zram, OOM and systemd conflict detection
  -> component selection / plan preview
  -> backup manifest preparation before the first write
  -> selected dependency installation and verified configuration
  -> KVM + graphics checks
  -> language tooling / Gradle / Docker
  -> wrapper installation
  -> verification report + backup manifest

User commands
  dev-doctor                -> read-only health report
  dev-build <command ...>   -> constrained build
  dev-run <profile> <cmd>   -> cgroup-contained workload
  dev-emulator <AVD>        -> KVM-accelerated, constrained emulator
  dev-profile <name>       -> inspect/select local profile (no root needed)
  dev-rollback <run-id>    -> review and reverse owned changes
```

Proposed repository layout (exact interfaces to be finalized in the approved implementation plan):

```text
setup.sh
config/
  defaults.conf
  profiles.conf
lib/
  common.sh
  preflight.sh
  packages.sh
  memory.sh
  virtualization.sh
  mise.sh
  gradle.sh
  docker.sh
  install-wrappers.sh
  backup.sh
bin/
  dev-run
  dev-build
  dev-emulator
  dev-doctor
  dev-profile
  dev-rollback
tests/
  unit/
  integration/
docs/
  superpowers/specs/2026-10-23-vaio-fe16-developer-workstation-design.md
  README.pt-BR.md
  PERFORMANCE.md
  TROUBLESHOOTING.md
examples/
  compose-limits.example.yaml
```

Modules must not mutate state when sourced. Mutations occur only through explicit functions during execution. A common command wrapper centralizes logging, privilege escalation, backup, atomic writes, and error handling. Each module advertises dependencies, install status, validation and owned paths to rollback metadata.

## 6. Functional Requirements

### FR-00 — Legacy source baseline and migration

1. The supplied snapshot already exists at `legacy/vaio-fe16-dev-setup/`, including its README and Compose example. Keep it unchanged and review the actual source before replacement. Record hashes of the supplied files; do not claim a match to an unavailable original ZIP. Do not run the legacy `setup.sh` on the target host during characterization.
2. Record the legacy behavior as follows (verified by source inspection): `setup.sh` installs Docker and earlyoom by default unless `--no-docker`/`--no-earlyoom` are passed; unconditionally manages user Gradle properties and zram-related `vm.swappiness=100` / `vm.page-cluster=0`; it makes root-file backups but does **not** have a full manifest rollback. `dev-run` uses `systemd-run --user --scope` with requested limits but has no independent verification that they are effective before launching the workload. The `bin` folder also contains `dev-build`, `dev-emulator` and `dev-doctor`.
3. The first implementation change is a read-only behavior map plus unit/characterization tests around the legacy flags, config edits, rollback gaps and wrapper failure behavior. All v2 changes are opt-in design migration; do not silently pretend old defaults already comply.
4. A new root `README.md` must describe v2 **only when v2 is implemented**. Until then, label the root readme as a review/development contract, keep old documentation in `legacy/vaio-fe16-dev-setup/README.md` and prohibit instructions that invite running the legacy installer as v2.

### FR-01 — Preflight and planning

1. `./setup.sh --check` must be **read-only**, show CPU topology, RAM, Mint version, cgroup availability, KVM/SVM, swap/zram, storage/free space, Mesa renderer, existing tools and suspicious conflicts.
2. `./setup.sh --dry-run` must preview selected modules, files and privileged commands **without mutating state, refreshing APT metadata or installing packages**. It may report unknown results if a prerequisite is absent.
3. Reject root execution. Request sudo only after user-facing preview/confirmation when mutations are necessary, with `--yes` available for deliberate unattended execution.
4. Offer `--only module[,module]`, `--skip module[,module]`, `--zram`, `--docker`, `--earlyoom`, `--gradle-global`, `--skip-mise` and explicit opt-in `--swappiness <0..200>`; reject unknown flags and contradictory combinations. Interpret legacy `--no-docker` and `--no-earlyoom` as harmless skip aliases for migration only. `--yes` must not implicitly select opt-in components.
5. Defaults: `zram=off`, `docker=off`, `earlyoom=off`, `gradle-global=off`, and VM sysctls unchanged. Baseline packages excluding memory managers, KVM prerequisites, mise integration (ON by default but skippable via `--skip-mise`), read-only diagnostics and wrappers may be proposed by an interactive preview. Creating or changing zram requires explicit `--zram` or interactive selection and approval. A selected invasive operation requires its own explicit confirmation and manifest entry; `--yes` confirms only the already selected, previewed operations.
6. Before any package installation or service action, inspect installed and active zram managers, swap devices and priorities, system and user OOM services, competing systemd units, and package-provider conflicts. Recheck relevant conflicts immediately before mutation; a conflict or indeterminate state stops that component without altering the existing manager.
7. Detect and stop on unsupported OS/platform before any write; tolerate unexpected CPU/RAM by warning and dynamically adapting defaults.
8. Log run IDs and actionable failure messages in a user-writable directory; never log passwords, tokens or environment-secret values.

### FR-02 — Packages and services

1. Install baseline packages for Git/Git LFS, C/C++ toolchain, CMake/Ninja, common native headers, Python build prerequisites, jq/ripgrep/fzf, diagnostics, Mesa/Vulkan and KVM. A zram package is selected only after `--zram` approval and conflict checks; it is not a baseline dependency.
2. Install only missing packages where feasible; surface conflicts rather than forcibly replacing vendor packages.
   Resolve package names and simulate the APT transaction after read-only conflict detection. Do not install `zram-tools`, `earlyoom` or another memory-management package as a side effect of baseline dependencies. For an approved memory component, account for package maintainer scripts that may start a unit during installation; do not allow a new manager to run with unreviewed defaults or beside an existing one.
3. Install Docker/Compose **only with `--docker`** (or selected `docker` module). Never auto-add the user to the privileged `docker` group; explain rootless Docker and `sudo docker` options. Merely generating a Compose example does not install or start Docker.
4. Do not auto-enable resource-consuming services unrelated to the requested components.
5. Preserve the existing distro Mesa AMD driver stack unless diagnostics show a verified compatibility issue.

### FR-03 — Memory and OOM safety

1. Preserve existing swap and zram devices, managers, configuration and priorities by default. An explicitly approved `--zram` installation may provision distro-supported zram only when no conflicting manager or unit exists. Its initial proposal is **logical zram size = 50% of physical RAM** (about 12 GB on 24 GB), **LZ4**, and elevated swap priority (e.g. 100); this is not 12 GB of permanently allocated RAM. Preview the chosen package, service and configuration before approval.
2. Complete read-only conflict detection before installing any memory-management package or touching a service. If an independent zram manager, conflicting swap policy or conflicting systemd unit exists, leave it unchanged and skip the component unless a separately reviewed migration is approved. Package installation must not accidentally activate a second manager.
3. Preserve existing disk swap and its priority; when new zram is approved, require its priority above disk swap where possible. Warn if no reliable emergency disk swap exists. Never disable swap globally or rewrite `/etc/fstab` by default.
4. **Do not write either `vm.swappiness` or `vm.page-cluster` by default.** Read and report the existing effective values, preserving any distribution/administrator policy. For an explicitly requested `--swappiness 100` (or another valid value), first confirm zram is active, identify any competing sysctl configuration, show a before/after preview, snapshot prior state and persist only the chosen key in an owned file. Do not change `vm.page-cluster` unless a separately scoped future design is approved. Treat 100 as a **testable hypothesis**, not a hardware optimum; benchmark under representative combined workloads. If zram setup fails, perform no VM tuning.
5. Prefer cgroup-bounded workloads as first-line memory protection. `earlyoom` is **off by default** and installed/enabled only with the explicit `--earlyoom` flag after displaying existing `systemd-oomd` (system and user), earlyoom and other discovered OOM/pressure services. If any conflicting protection is active or cannot be determined, refuse to enable an additional daemon; do not stop, disable or replace existing services automatically.
6. If earlyoom is explicitly selected and no conflict exists, preview its policy and consequences (including possible termination of apps), back up its configuration, and verify the service after enabling; never promise recovery from all memory pressure.
7. Any pressure/kill policy must prefer sacrificing a constrained build to sacrificing the interactive desktop; document that a process may be terminated at `MemoryMax`.

### FR-04 — CPU, power and thermal behavior

1. Do not force `performance` governor, set `amd_pstate` kernel options or run `powertop --auto-tune` by default.
2. Report driver, available power profiles, AC/battery state when detectable, throttling indicators and temperatures **as diagnostics**, not invented benchmarks.
3. Default profile prioritizes simultaneous responsiveness; provide an **opt-in high-throughput profile** without removing memory limits. Profile changes affect subsequent commands rather than silently modifying running workloads.
4. Never advertise increased sustained CPU speed without reproducible measurement. Thermal throttling may limit this 15 W-class notebook.

### FR-05 — `mise` and backend toolchains

1. Install or reuse `mise`; activate it in interactive Bash and existing Zsh startup files without duplicate entries, and verify it works in a fresh login shell.
2. If a preinstalled `mise` comes from another package manager, do not overwrite its binary or activate contradictory paths.
3. Honor project-local version manifests. No unsolicited global Go, Python, Node, Java or .NET versions. Offer an explicitly opt-in setup example for these stacks and Protocol Buffers/Buf tooling.
4. Provide clear guidance for IDEs/noninteractive tools to use `mise exec`/shims when shell startup files are not read.
5. Do not change repositories, commit tooling state or enable insecure trust settings automatically.
6. For an absent `mise`, use the upstream **manual Linux x64 release artifact** method, not a downloaded installer script or an added APT repository. The implementation plan must select and record one explicit release version and its official GitHub release URL. Download the executable, `SHASUMS256.txt` and `SHASUMS256.txt.minisig` into a private temporary directory; verify the checksum manifest with distribution-packaged `minisign` against the pinned upstream public key `RWTC3g8W3z4RZK3V3qv7fa1QY4JEWyBtqIHW+85QlJpZc5yG+uNYNBSZ`, then verify the executable's SHA-256 entry before atomic installation. This key and procedure come from the official [mise manual installation guide](https://mise.jdx.dev/installing-mise.html#manual-download); record the resolved version and artifact digest in the install manifest. Any missing signature, mismatch, unavailable verifier or untrusted source stops the `mise` component without executing or installing the artifact and prints manual instructions. Reuse an existing installation without replacing its owner or path.

### FR-06 — Gradle and Android development

1. **Default: project-level guidance only.** Generate documented examples for a project's root `gradle.properties` or per-invocation flags; do not write any project Gradle file or `~/.gradle/gradle.properties` unless expressly requested. `dev-build` must not silently impose Gradle properties globally.
2. Optional **`--gradle-global`** activates a separately previewed and confirmed managed block in the detected `GRADLE_USER_HOME/gradle.properties` (default `~/.gradle/gradle.properties`). Preserve existing content, pre-existing managed blocks, permissions and ownership; make a verifiable backup/manifest entry. Report conflicts and refuse to shadow any existing same-key property outside the managed block without a separate explicit resolution. `--yes` alone cannot enable global configuration.
3. Suggested **opt-in** properties for evaluated projects: daemon `-Xmx3g`, `MaxMetaspaceSize=768m`, `org.gradle.workers.max=4`, build cache on and 15-minute daemon idle timeout. Evaluate `org.gradle.parallel=true` by project (off unless explicitly chosen); configuration cache is likewise per-project. Do not claim a 3 GiB heap bounds Kotlin daemons, workers or detached Gradle processes. Verify precedence: command-line arguments may override properties, whereas `GRADLE_USER_HOME/gradle.properties` takes precedence over project settings.
4. If `GRADLE_USER_HOME` is set, resolve and display it; never assume `~/.gradle`. Do not overwrite project-pinned settings, remove existing user settings or change another project's behavior without opt-in.
5. Do not force configuration cache or parallel execution globally; recommend per-project evaluation and document compatibility overrides.
6. The supported isolated Gradle recipe is `dev-build ./gradlew assembleDebug --no-daemon` (or the equivalent task). `--no-daemon` may still launch a **single-use daemon**; acceptance must observe that temporary daemon, compiler processes and Gradle workers inside the verified build cgroup. Do not claim isolation for a Gradle command that reuses an already running daemon outside the scope. Generic `dev-build` launches and Android Studio's own builds require separate process-tree verification or an explicit limitation in diagnostics and documentation.
7. Prefer official Android Studio installation or a clearly opt-in, verified download module; never install AVD images silently.
8. Configure/test **AMD-V/SVM + KVM**, `/dev/kvm` user permissions and a Linux x86_64 Android system image. If BIOS virtualization is disabled, report manual action required; never claim the installer can change firmware settings.
9. `dev-emulator --list` lists AVDs. `dev-emulator <name> ...` checks emulator binary, AVD existence, x86_64 system-image compatibility and KVM readiness before launching with **`-accel on`**. Initial guest defaults are **4 vCPUs**, **3 GiB RAM**, GPU `auto` and boot animation disabled. Reject extra arguments that disable acceleration or override enforced launch settings. The emulator's host CPU, RAM, swap and task ceilings come from its independently verified cgroup, regardless of AVD guest settings.
10. Detect renderer failures and offer documented alternative GPU modes without silently changing KVM acceleration or forcing software rendering for every device.
11. Explain that an emulator launched from Android Studio may evade wrapper constraints; offer an explicit terminal launch or optional IDE launcher/profile with clearly stated limitations.

### FR-07 — Resource isolation wrappers

`dev-run` must execute each requested program in a `systemd --user --scope` cgroup v2 workload using `CPUQuota`, `MemoryHigh`, `MemoryMax`, `MemorySwapMax` and `TasksMax`, plus lowered scheduler and IO priorities where supported. **Requesting** unit properties via `systemd-run` is insufficient to claim fail-closed behavior. The payload MUST remain unexecuted until the launcher verifies the effective scope controls. `DEV_LIMITS_DISABLED=1` is an intentional separate unsafe mode requiring an unmistakable warning and is never enabled automatically.

**Required pre-exec gate protocol (implementation acceptance contract):**

1. Generate a unique transient `.scope` unit name and a private, mode-0700 control directory under `$XDG_RUNTIME_DIR` (if absent/unwritable, fail). Start a tiny bundled *gate helper* inside the scope which waits for a parent release signal/handshake and has not executed any part of the requested payload. Preserve arguments as an array; never use `eval` or concatenate an executable command string.
2. The parent waits with a finite timeout until the helper reports its process PID and the transient scope is active. Verify by querying `systemctl --user show <unit>` for `ControlGroup`, `ActiveState` and requested resource properties, then obtain the gate-helper's `/proc/<pid>/cgroup` membership. Membership MUST correspond to the expected transient unit. Do not rely only on unit properties.
3. Inspect the scope's **actual** cgroup v2 files `cpu.max`, `memory.high`, `memory.max`, `memory.swap.max` and `pids.max` under `/sys/fs/cgroup/<ControlGroup>`; verify they exist, are finite (not `max`), and enforce bounds **at least as strict as** the configured profile. For CPU parse `quota period` and compare the numerical ratio to profile `%`; compare memory, swap and task bounds as bytes/integers. Account for potentially stricter parent cgroups; report stricter-than-profile effective limits instead of claiming capacity guaranteed.
4. Release the helper **only after** the systemd unit, gate-helper membership and kernel cgroup limit checks pass; the helper then `exec`s the original command under that same cgroup. Ordinary child processes inherit that cgroup. Validate payload and representative child membership while running; separately launched user services, existing daemons and containers remain outside the wrapper's contract. If verification fails, the unit disappears, membership differs or timeout occurs: terminate helper/scope, remove gate resources, return nonzero, and prove that the requested payload **never launched**.
5. Propagate the payload's real exit status and SIGINT/SIGTERM; clean up resources on success/failure without allowing the child to escape the scope. A wrapper's signal or interrupted handshake must not leave a blocked helper or orphaned payload. This implementation may use a private FIFO or equivalent authenticated local IPC. No user-supplied command is executed for mere preflight.
6. `--check` and `dev-doctor` may report only *capability*; a live scope self-test with gate synchronization is required to report runtime enforcement. No standalone systemd scope is a system-wide resource reservation.

**Initial balanced profile, designed for 24 GB of RAM:**

| Workload | CPU quota | MemoryHigh | MemoryMax | MemorySwapMax | TasksMax |
| --- | ---: | ---: | ---: | ---: | ---: |
| Build (`dev-build`) | 800% | 7 GiB | 9 GiB | 2 GiB | 1024 |
| Emulator (`dev-emulator`) | 400% | 5 GiB | 6 GiB | 1 GiB | 512 |
| Other heavy (`dev-run heavy`) | 600% | 6 GiB | 8 GiB | 2 GiB | 768 |

CPU quota percent denotes time equivalent to that many **logical CPU threads**, not core pinning. `MemoryHigh` is a reclaim/throttling threshold; `MemoryMax` is a hard cap that can lead to a cgroup-local OOM kill. Quotas must be recalculated or rejected appropriately when actual hardware differs. One scope per launched workload, with recognizable transient unit names for diagnostics. These are **independent upper bounds**: 9 GiB build plus 6 GiB emulator does **not** reserve the remaining 9 GiB for the host, IDE or Docker, and memory accounting may include page cache. Docker and preexisting IDE/Gradle daemons are outside these per-scope budgets unless launched/limited separately. Measure simultaneous host demand before increasing limits.

`MemorySwapMax` limits swap charged to a scope in addition to `MemoryMax`; it does not disable host swap. These are conservative **initial ceilings**, configurable in the user-owned profile for future launches after preview. On the 24 GB VAIO, begin with one build and one emulator, record peak `memory.current`, `memory.swap.current`, `memory.events`, PSI and desktop latency on repeated representative workloads, then adjust one ceiling at a time only when the observed peak and host reserve justify it. Do not increase all independent ceilings together or infer a sustained-performance gain without measurement.

`dev-build` must preserve argument boundaries and propagate exit codes/signals. It may set workload-local defaults such as `GOMAXPROCS` / `CARGO_BUILD_JOBS` / `CMAKE_BUILD_PARALLEL_LEVEL`, never force them globally. Support Go, Gradle, .NET, Python and npm/pnpm/yarn commands without knowledge of each tool's project structure.

**Important boundary:** Limiting a direct wrapper process does not automatically constrain all work from a separately running Android Studio, detached Gradle daemon, external build server or Docker engine. Documentation and tests must not suggest otherwise.

### FR-08 — Docker and local services

1. Default `--docker` is OFF. Require the explicit `--docker` flag/selected module and detect Docker CE vs distro packages before any installation; report actions in preview. The legacy default-on behavior must not survive into the v2 root README.
2. Provide example Compose configurations with bounded CPU, memory and PID counts for PostgreSQL and Valkey, bind ports to localhost, require secrets from environment, and avoid storing real credentials in files.
3. Do not assert that app-level `dev-run` resource caps govern Docker daemon/containers. Containers use their own limits.
4. Explain Docker rootless prerequisites and any cgroup delegation restrictions. Use `docker stats` to verify actual consumption.

### FR-09 — Diagnostics and observability

`dev-doctor` must remain read-only and produce human-readable Portuguese output; optional `--json` emits stable machine-readable keys. Report OS/CPU, RAM, swap/zram, `vm.*` effective values, KVM, Mesa/Vulkan, thermals where available, power policy, user cgroup controllers, Gradle settings, mise, SDK/AVDs, Docker version, tool paths and install manifest. Distinguish **PASS / WARN / FAIL / NOT INSTALLED**. Never call a test successful if it was not executed.

Optional `dev-benchmark` can record baseline versus post-install timing, peak RAM, swap activity, CPU throttling, and emulator boot duration. Benchmarks must use comparable workloads and must not manufacture a claim of improvement when measurements are unavailable.

### FR-10 — Rollback and maintenance

1. **Before any host tuning is enabled**, implement and test backup, dry-run, manifest and rollback. For every modified preexisting file, create a durable backup with owner, mode and contents intact before mutation; record original path, original checksum, post-write checksum, owner, module, operation and run ID in a stable manifest. Record newly created files separately from modified files and record service/package status before mutation.
2. Use atomic writes for system/user configuration files when possible; on interrupted module setup, restore only changes safely owned by that module or print an exact manual recovery procedure with backups. Do not force-remove third-party packages.
3. `dev-rollback --list` previews available runs; `dev-rollback <run-id> --dry-run` previews undo; actual rollback requires confirmation and refuses to overwrite a file modified after setup without explicit approval. A checksum mismatch defaults to a safe skip/error, not destruction; manual conflict resolution is a separate act.
4. Remove only clearly owned blocks, files and services installed/enabled by this toolkit. Never uninstall dependencies that another package or user may depend on without approval.
5. Document what rollback **cannot** restore (unrelated package upgrades, manually changed BIOS settings, data created by developers, downloaded SDKs).

## 7. Nonfunctional Requirements

- **Security:** no `curl | sh`; verify publisher/source and checksums/signatures where available; never log secrets, lower file permissions or globally disable mitigations. Make the third-party `mise` bootstrap explicitly reviewable.
- **Reliability:** set `set -Eeuo pipefail` where appropriate, quote arguments, avoid globbing bugs, handle interruption via traps, verify each changed service with relevant status commands.
- **Idempotence:** successive runs must not produce duplicate entries or repeatedly restart working services without need.
- **Compatibility:** avoid Mint-version-specific assumptions when an equivalent feature can be discovered; support Bash and optional Zsh.
- **User experience:** concise Portuguese terminal messages; flags, help, risks, privilege prompts and manual steps explained; English source and Git history using Conventional Commits/Branches.
- **Maintainability:** testable small modules, no unnecessary abstraction, ShellCheck/shfmt, structured errors and configuration defaults separate from control logic.
- **Reproducibility:** note package/source versions and environment in a diagnostic manifest; do not claim binary-exact reproducibility of unpinned APT repos.

## 8. Implementation Boundaries and Ownership

| Subsystem | Owns | Must not do |
| --- | --- | --- |
| Preflight | Compatibility/status report, dependency graph | Change package state in `--check` or `--dry-run` |
| Memory | zram managed config, toolkit sysctl file, selected OOM daemon policy | Delete swap, conflict with other zram/OOM managers |
| KVM/graphics | Install prerequisites, validate device access, instruct on BIOS and GPU | Override proprietary drivers/kernel flags automatically |
| Toolchains | mise activation, optional packages, wrapper paths | Impose global SDK versions or rewrite project manifests |
| Android | Project-level Gradle guidance, optional global managed block, emulator command | Edit global Gradle settings without opt-in or guarantee IDE launches inherit limits |
| Containers | Optional Docker install, Compose examples | Give unbounded privileged socket access to user |
| Wrappers | Per-command systemd scope and exit-status integrity | Silently run unlimited when cgroups fail |
| Backup/rollback | Manifest, file snapshots, safe reversions | Undo user's later edits without explicit consent |

## 9. Acceptance Criteria

**AC-01: Safe preview.** `setup.sh --check` and `--dry-run` leave checksums of tracked config files, package selections and service states unchanged.

**AC-02: Idempotence.** Run setup twice on a clean supported VM/mock environment. Managed config blocks occur exactly once; second pass reports no unintended changes.

**AC-03: zram correctness and preservation.** Default setup leaves existing swap and zram configuration unchanged and installs no zram manager. With explicit `--zram` approval and no conflict, `zramctl`, `swapon --show` and config agree about active algorithm, capacity and priority. If another manager or unit exists, no conflicting package is installed and no service or swap configuration is changed.

**AC-04: Protection under pressure.** In an isolated host/VM test, exercise a synthetic workload over `MemoryMax` and separately over `MemorySwapMax`; verify the workload scope records relevant memory and swap events while desktop/session services survive. Host swap remains enabled and preexisting swap/zram state is preserved by default. Confirm no new zram manager, earlyoom daemon or VM sysctl is enabled during default setup. No universal freeze-free guarantee is made.

**AC-05: Cgroup fail-closed.** A controlled gate-helper test proves that the payload does not start while scope verification is pending. Query both `systemctl --user show` and **kernel files** `cpu.max`, `memory.high`, `memory.max`, `memory.swap.max`, `pids.max`; check membership and numerical bounds before releasing the payload. Inject no delegation, absent or ineffective controller, `max`/unbounded control, wrong cgroup membership, timeout, interrupted gate and scope teardown; in all cases the sentinel payload is **not executed**. Confirm payload and ordinary child membership, exit statuses, and signal/cleanup behavior on the success path.

**AC-06: KVM readiness.** On hardware with SVM enabled, `kvm-ok` and `emulator -accel-check` verify acceleration; a compatible x86_64 AVD launched by the wrapper uses `-accel on`. Missing KVM access, an incompatible AVD or a conflicting extra argument prevents launch with actionable diagnostics. If SVM is disabled, `dev-doctor` provides BIOS instructions and marks the check incomplete/failing.

**AC-07: Android practical use and responsiveness.** On the actual VAIO with a ready x86_64 AVD and KVM, run one `-accel on` emulator (4 vCPU, 3 GiB guest RAM), Android Studio, one `dev-build ./gradlew assembleDebug --no-daemon` build and optional bounded Docker workloads **concurrently for a 30-minute observation window**. Verify scope membership of the emulator, Gradle's single-use daemon, compiler processes and workers; deliberately attempt a reused-daemon case and report it outside the isolation guarantee. Record per-scope CPU, peak memory, peak swap, `memory.events`, `memory.swap.events`, host `MemAvailable`, swap/zram statistics, CPU/IO/memory PSI, temperature and repeatable interactive-latency samples versus an idle baseline. Pass only if scoped workloads stay within verified CPU, memory, swap and task limits, the GUI/session survives, no host-wide OOM occurs and any worsening in responsiveness is explicitly reported and accepted after tuning; do not claim absolute FPS/latency or faster builds without real measurements. If Docker is absent, record `NOT INSTALLED`, not a pass.

**AC-08: mise behavior and trust.** Existing installation is respected, project-local versions take precedence, Bash/Zsh hooks are not duplicated, and CLI commands function after a fresh shell login. The new-install path accepts only an explicit release artifact whose checksum manifest verifies against the pinned upstream minisign key; missing or invalid signature, checksum or verifier prevents installation and execution.

**AC-09: Docker isolation.** Fresh default setup leaves Docker absent/untouched; explicit `--docker` installs only after preview. With Docker opted in, example PostgreSQL/Valkey containers respect declared limits, ports bind to localhost and the user is not implicitly granted docker-root privileges.

**AC-10: Rollback integrity.** Before touching the host, unit/integration tests prove manifest creation, backup permissions, idempotent re-runs, interrupted write recovery, new-file cleanup, edited-file conflict detection and no silent clobbering on rollback. Reversion of packages and services is restricted to owned changes; preexisting administrator state survives.

**AC-11: Error paths.** Test unsupported OS, missing network, package-manager conflicts, root invocation, no `/dev/kvm`, incompatible or missing x86_64 AVD, missing Android SDK, non-delegated or ineffective CPU/memory/swap/task controllers, zram and OOM manager conflicts before package installation, insufficient disk space, missing sudo access and interrupted runs. All fail with actionable diagnostics and leave preexisting host configuration intact.

**AC-12: Documentation.** Root `README.md` and/or `docs/README.pt-BR.md` clearly distinguish legacy from v2. On v2 delivery they agree that zram changes, Docker, earlyoom, VM sysctls and global Gradle edits are OFF by default; give explicit opt-in flags; show check/dry-run, reboot/login requirements, signed mise installation, Go/.NET/Node/Kotlin/Gradle workflows including `--no-daemon`, forced KVM for wrapper launches, isolated-wrapper and external-daemon limitations, swap-limit calibration, performance measurement and manifest rollback. The unchanged legacy README remains under `legacy/` solely for source review.

## 10. Test and Verification Strategy

1. **Static:** `bash -n`, ShellCheck and shfmt checks on every Bash file; YAML lint for Compose samples.
2. **Unit:** Bats (or equivalent) with fake command stubs and temporary HOME for flags, detection before APT, resource-profile math including swap limits, defaults (zram/Docker/earlyoom/global Gradle/sysctl OFF), shell activation, signed `mise` artifact verification, manifest creation, post-edit checksum conflicts and signal/exit propagation. Include gated-wrapper tests with a sentinel command that MUST NOT start when any CPU, memory, swap or task verification fails, plus child-process membership checks.
3. **Integration:** disposable Ubuntu 24.04/Mint-compatible VM for package operations, pre-install zram/OOM conflicts, manifest/rollback, interrupted installation, swap exhaustion and live systemd scopes. Exercise a Gradle build with an existing reusable daemon and a `--no-daemon` build with a single-use daemon, checking daemon/compiler/worker membership. A container may test pure logic but is insufficient for claims about systemd controller delegation or KVM. Tests for rollback/idempotence MUST pass before any host-tuning implementation is exercised on the real machine.
4. **Hardware acceptance:** VAIO FE16 on a fresh supported Mint installation. Verify AMD-V, graphics acceleration, actual cgroup enforcement, unchanged default VM sysctls and simultaneous emulator + build + IDE coexistence on AC power and under thermal load, with Docker measured when opted in.
5. **Before/after observation:** preserve a baseline (idle RAM, swap, startup, one representative backend build, Gradle build, Android boot). Run the same workloads repeatedly after tuning and report median times, peak RAM and whether responsiveness regressed; make no unsupported speed claims.
6. **Failure injection:** simulate network outage, invalid `mise` signature/checksum, terminated package install, failed or ineffective systemd controllers, disabled SVM, incompatible AVD and conflicting zram/OOM managers; demonstrate safe recovery without launching an unbounded payload or changing preexisting manager state.

## 11. Phased Delivery (for later planning)

- **Milestone 1 — Foundation:** repository structure, preflight, dry-run, logging, manifest and idempotence tests.
- **Milestone 2 — Safe host tuning:** packages, zram/swap/OOM policy, AMD/KVM diagnostics and rollback.
- **Milestone 3 — Dev environments:** mise, Gradle, Android SDK guidance, optional Docker and Compose examples.
- **Milestone 4 — Controlled workloads:** dev-run/dev-build/dev-emulator, profiles, cgroup checks and failure behavior.
- **Milestone 5 — Confidence:** dev-doctor, documentation, static/unit/integration checks, VAIO acceptance and benchmark report.

Each milestone must finish in a separately testable deliverable. Do not implement until the design has been approved and a Superpowers implementation plan has been written.

## 12. Review Resolution and Pending Approval

The owner approved incorporating these policies into the **design only**. The supplied prior art exists at `legacy/vaio-fe16-dev-setup/` and remains unchanged. V2 retains the useful CLI workflows, bounded Compose example and KVM diagnostics while correcting legacy default-on Docker/earlyoom, global Gradle and VM writes, unverified mise bootstrap, and unverified scope limits.

- **Memory:** existing swap and zram are preserved; new zram requires explicit approval. Build, emulator and heavy profiles have independent RAM and swap ceilings verified in kernel cgroup files before payload release. Actual VAIO measurements govern later profile changes.
- **Gradle:** project-level guidance and `--no-daemon` are the supported scoped recipe; global properties require separate opt-in. A single-use daemon and its workers must be observed in the scope; preexisting or IDE-launched daemons are outside the generic wrapper guarantee.
- **Android:** the wrapper requires KVM and a compatible x86_64 AVD, launches with `-accel on`, and keeps GPU `auto` unless the user selects a documented graphics fallback.
- **Packages:** read-only swap/zram/OOM/unit conflict detection precedes APT or service changes. Docker and earlyoom are opt-in; package installation must not start a conflicting memory manager.
- **Toolchain trust:** absent mise is installed only from an explicit upstream release artifact after signed-manifest and artifact-hash verification. No downloaded installer script is executed.
- **Recovery:** manifest, backup, idempotence, interruption and rollback tests precede persistent host tuning. Documentation distinguishes v1 from proposed v2 and never promises rollback of unrelated package upgrades.

**Remaining owner sign-off:** this is still a proposal. Final design approval authorizes the `superpowers:writing-plans` implementation plan, not execution of setup or host tuning. The following planning choices are delegated to the builder within these approved design boundaries:

1. Treat Mint 22.3 Cinnamon as the primary validated target and other Mint 22.x as best-effort on the Ubuntu Noble base; verify the installed release before mutation.
2. Use modular Bash and the supplied legacy behavior map; avoid adding Ansible or Nix.
3. Begin with the FR-07 per-workload limits; calibrate from the specified VAIO concurrency test before offering a faster profile.
4. Keep Android Studio/SDK installation opt-in with an official-download guide.
5. Preserve existing disk swap; never create or repartition it automatically.
6. Make rollback conservative and refuse to overwrite later user edits.

## 13. Sources and References

- AMD Ryzen 7 5825U specifications: https://www.amd.com/en/support/downloads/drivers.html/processors/ryzen/ryzen-5000-series/amd-ryzen-7-5825u.html
- Linux Mint release compatibility: https://linuxmint.com/download_all.php
- Android Emulator hardware acceleration / KVM: https://developer.android.com/studio/run/emulator-acceleration
- Android Studio: https://developer.android.com/studio
- systemd resource controls: https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html
- Linux cgroup v2 memory and swap controls: https://www.kernel.org/doc/html/latest/admin-guide/cgroup-v2.html
- Gradle precedence / properties: https://docs.gradle.org/current/userguide/project_properties.html
- Gradle build environment: https://docs.gradle.org/current/userguide/build_environment.html
- Linux kernel swappiness: https://kernel.org/doc/html/latest/admin-guide/sysctl/vm.html
- systemd-run scope semantics: https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html
- Gradle performance: https://docs.gradle.org/current/userguide/performance.html
- mise shell activation: https://mise.jdx.dev/shell-setup.html
- mise signed release artifact installation: https://mise.jdx.dev/installing-mise.html#manual-download

## 14. Superpowers Handoff

On approval, invoke **`superpowers:writing-plans`** and produce:

`docs/superpowers/plans/2026-10-23-vaio-fe16-developer-workstation.md`

The plan must cite this spec, preserve its exact defaults, assign concrete file paths and interfaces, define failing tests before production changes, include frequent Conventional Commits in English, and require verification after each independent task. Choose the actual execution method only after the plan is reviewed; do not treat this proposed design as implicit permission to install or modify the user's computer.
