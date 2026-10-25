# VAIO FE16 Developer Workstation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task by task. Track each step with its checkbox. Neither this plan nor design approval authorizes running setup on the physical VAIO.

**Goal:** Deliver an inspectable, idempotent and conservatively reversible Linux Mint 22.x workstation toolkit that keeps scoped builds and one KVM Android Emulator within verified CPU, RAM, swap and task ceilings.

**Architecture:** Bash remains the entry point and workload interface. Small sourced modules perform read-only discovery and explicit mutations; a Python 3 standard-library journal handles durable JSON records and path escaping before any host write. A blocked gate process enters a named systemd user scope, and the parent checks kernel cgroup files before releasing the workload. Existing legacy files remain immutable.

**Tech Stack:** Bash, Python 3 standard library for JSON journaling, systemd user scopes/cgroup v2, APT on Mint 22.x, Bats for shell tests, ShellCheck, shfmt and yamllint as development tools.

**Spec:** docs/superpowers/specs/2026-10-23-vaio-fe16-developer-workstation-design.md, approved Revision 3. Read it and REVIEW-DECISIONS.md before executing any task.

## Global constraints

- Target Linux Mint 22.x Cinnamon on Ubuntu Noble, x86_64; validate primarily on 22.3 and test other 22.x as available. Detect actual RAM and CPU; initial limits target Ryzen 7 5825U, 16 logical threads, 24 GB RAM.
- Technical documentation, source, tests, identifiers and Conventional Commits are in English per the owner's latest instruction. Terminal messages remain Brazilian Portuguese as specified by the design.
- Run setup as the logged-in user; use sudo only for a previewed system mutation. Check and dry-run never run sudo, APT update, package installation or state-writing commands.
- Preserve existing swap, zram, OOM services, VM sysctls, Gradle files, Docker installations and mise installations. New zram, Docker, earlyoom, global Gradle settings and swappiness changes require explicit independent selection. No partition, fstab, bootloader, kernel-flag or firmware edits.
- Every installed artifact or changed service needs a before-state journal entry, owned path, durable backup when applicable, post-state checksum/status and conservative rollback. A checksum conflict stops automatic restoration. Package upgrades and user data are not promised reversible.
- A limited workload never starts if CPU, memory.high, memory.max, memory.swap.max, pids.max or scope membership cannot be verified. DEV_LIMITS_DISABLED=1 is an explicit warned escape hatch only.
- Balanced limits: build CPU 800%, MemoryHigh 7 GiB, MemoryMax 9 GiB, MemorySwapMax 2 GiB, TasksMax 1024; emulator 400%, 5 GiB, 6 GiB, 1 GiB, 512; heavy 600%, 6 GiB, 8 GiB, 2 GiB, 768. These are per-scope provisional ceilings, not a host reservation.
- No host installation, live resource pressure or physical VAIO tuning during planning. During implementation, run privileged integration work only in a disposable Mint-compatible VM. Physical acceptance requires a later deliberate install authorization.
- In the disposable Noble-based VM only, prepare development tools with sudo apt-get update followed by sudo apt-get install -y bats shellcheck shfmt yamllint python3 minisign. These are test prerequisites; do not install them on the physical VAIO merely to execute this plan. Record resolved APT versions in VM evidence.

## File map and interfaces

| Path | Responsibility |
| --- | --- |
| setup.sh | CLI parsing, module selection, preview/confirmation, ordered orchestration |
| config/profiles.conf | Shipped read-only tab-separated balanced profile table: profile, CPU percent, RAM high/max, swap max, task max; never sourced as shell code |
| lib/common.sh | Portuguese logging, privilege guard, command checking, safe temporary files |
| lib/preflight.sh | Mint/hardware discovery and read-only package, swap, zram, OOM, unit and tool conflict report |
| lib/manifest.py | Python standard-library append-only JSONL run journal, fsync, safe listing and event validation |
| lib/backup.sh | Run creation, durable snapshots, atomic owned file writes and state recording |
| lib/rollback.sh | Preview and conservative reversal of owned file, service and package changes |
| lib/packages.sh | APT simulation, missing-package selection, provider conflict checks, audited apply |
| lib/memory.sh | Explicit zram, earlyoom and swappiness modules, preserving existing swap |
| lib/virtualization.sh | KVM/SVM, /dev/kvm, Mesa and Android acceleration diagnostics |
| lib/mise.sh | Existing-binary reuse and signed, pinned upstream artifact installation; shell hooks |
| lib/gradle.sh | Project-level advice and separately selected global managed block |
| lib/docker.sh | Explicit Docker package/service selection and conflict checks |
| lib/install-wrappers.sh | Idempotent installation of owned commands into user bin |
| bin/dev-run, bin/dev-gate | Scoped launcher and blocked helper with kernel-control verification |
| bin/dev-build | Workload-local build concurrency and Gradle isolation recipe |
| bin/dev-emulator | x86_64 AVD and KVM checks, forced acceleration, scoped launch |
| bin/dev-doctor | Read-only Portuguese and stable JSON health report |
| bin/dev-profile | Read/choose user-owned limits for future launches; never silently alter running scopes |
| bin/dev-rollback | User CLI for list, dry-run and confirmed rollback |
| examples/compose-limits.example.yaml | Bounded localhost PostgreSQL and Valkey example without credentials |
| tests/unit/*.bats, tests/unit/test_manifest.py | Stubbed unit, documentation-contract and journal tests with temporary HOME/state |
| tests/integration/*.bats, tests/integration/run-vm.sh, tests/acceptance/vaio-checklist.md | Disposable-VM checks and separate physical-hardware evidence checklist |
| docs/USAGE.md, docs/GRADLE.md, docs/PERFORMANCE.md, docs/TROUBLESHOOTING.md, README.md | English technical usage, measurement and recovery; root README changes from handoff to actual v2 only at delivery |

Stable shell interfaces: preflight_host and preflight_conflicts print key=value lines without writes; setup consumes these as data, never sources their output. begin_run prints a run ID and creates a mode-0700 run directory under XDG_STATE_HOME/vaio-fe16-dev-setup/runs. snapshot_file, install_owned_file, record_package_state and record_service_state in lib/backup.sh take run ID and explicit paths/names. lib/manifest.py supports init, append, list and verify commands over that run directory; each event has run_id, module, action, target, before state, intended after state, backup path and timestamp. lib/rollback.sh exposes rollback_preview RUN_ID and rollback_apply RUN_ID. All readers treat journal contents as data, never shell code. State changes use compare-before-write and record intent before mutation so interruption has an exact recovery path.

## Review focus

- Existing zram manager or swap policy: Task 6 tests that even package installation is skipped, with no second unit started.
- Existing or partially edited Gradle properties and shell hooks: Tasks 8 and 9 test no duplicate managed keys, unchanged unrelated content and checksum-safe rollback.
- A cgroup controller accepted by systemd but ineffective in the kernel: Task 5 tests that a sentinel payload and its children never start.
- A previously running Gradle daemon or Android Studio build: Task 10 tests the documented isolation boundary and the single-use daemon path.
- Missing signature, changed artifact, AVD architecture mismatch or KVM failure: Tasks 8 and 11 test fail-safe refusal and actionable diagnostics.

## Spec coverage map

| Approved requirement | Owning tasks |
| --- | --- |
| FR-00 legacy preservation | 1 |
| FR-01 read-only preflight and planning | 2, 16 |
| FR-02 packages and service conflicts | 6, 12, 16 |
| FR-03 memory, swap and OOM safety | 5, 7, 17 |
| FR-04 power, thermal and profiles | 13, 14, 18 |
| FR-05 mise and toolchains | 8 |
| FR-06 Gradle and Android | 9, 10, 11 |
| FR-07 verified resource isolation | 5, 10, 11 |
| FR-08 Docker | 12 |
| FR-09 diagnostics and observations | 13, 17, 18 |
| FR-10 backup and rollback | 3, 4, 15, 16 |
| AC-01–AC-03 preview, idempotence and zram | 2, 7, 16, 17 |
| AC-04–AC-07 memory pressure, cgroups and emulator | 5, 10, 11, 17, 18 |
| AC-08–AC-12 mise, Docker, rollback, errors and docs | 4, 8, 12, 16, 17, 18 |

---

### Task 1: Preserve and characterize the legacy baseline

**Files:** Keep legacy/vaio-fe16-dev-setup/** unchanged. Create tests/unit/legacy_behavior.bats, tests/fixtures/legacy.sha256 and tests/README.md.

**Interfaces:** Produces a read-only behavior map and file hashes used by later regression tests. No runtime v2 interface.

- [ ] **Step 1: Write characterization tests.** Assert legacy setup defaults Docker and earlyoom on, writes user Gradle and two VM sysctls, keeps --check read-only by source-path inspection, and dev-run requests four limits without kernel-file validation. Assert legacy dev-build forwards argument boundaries and legacy Compose limits and localhost binds.
- [ ] **Step 2: Run the tests against the supplied legacy files.** Run: bats tests/unit/legacy_behavior.bats. Expected: PASS for observed behavior. Run: sha256sum -c tests/fixtures/legacy.sha256. Expected: PASS for every supplied legacy file. This is characterization; the v2 safety assertions in later tasks must first fail.
- [ ] **Step 3: Record only the supplied snapshot's hashes and factual behavior in tests/README.md.** State that no original ZIP checksum is available and never execute legacy setup for characterization.
- [ ] **Step 4: Verify shell syntax without executing scripts.** Run: bash -n legacy/vaio-fe16-dev-setup/setup.sh legacy/vaio-fe16-dev-setup/bin/dev-*. Expected: exit 0. Run the two checks from Step 2 again; expected PASS.
- [ ] **Step 5: Commit.** Stage only legacy/vaio-fe16-dev-setup, README.md, REVIEW-DECISIONS.md, docs/superpowers/specs/2026-10-23-vaio-fe16-developer-workstation-design.md, docs/superpowers/plans/2026-10-23-vaio-fe16-developer-workstation.md, tests/unit/legacy_behavior.bats, tests/fixtures/legacy.sha256 and tests/README.md. Run: git commit -m "test: characterize supplied legacy workstation scripts". Leave unrelated untracked files out.

### Task 2: Read-only preflight, CLI parsing and preview

**Files:** Create setup.sh, lib/common.sh, lib/preflight.sh, tests/unit/preflight.bats and tests/unit/setup_cli.bats.

**Interfaces:** preflight_host emits OS, CPU thread count, MemTotal, storage and cgroup facts; preflight_conflicts emits installed/active zram, swap, OOM, systemd-unit and Docker-provider facts. setup.sh exposes --check, --dry-run, --only, --skip, --zram, --docker, --earlyoom, --gradle-global, --swappiness, --skip-mise and --yes. Unknown or contradictory options return 2. No mutation function is invoked yet.

- [ ] **Step 1: Write failing tests.** With stubbed commands and temporary HOME, assert --check and --dry-run report Mint 22.x/Noble hardware facts, conflicts and selected operations without calls to sudo, apt-get, tee or file writes; root/unsupported OS/unknown flags fail; --yes alone selects none of the opt-in modules; --only versus --skip conflicts fail.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/preflight.bats tests/unit/setup_cli.bats. Expected: FAIL because v2 entry point/functions are absent.
- [ ] **Step 3: Implement only parsing, discovery and preview.** Detect /etc/os-release and uname, read /proc/meminfo and cgroup capabilities, inspect package/service state without changing it, and print an operation preview. Require a normal user before any eventual mutation. Keep command invocations injectable through PATH for tests.
- [ ] **Step 4: Verify green.** Run the Step 2 command and bash -n setup.sh lib/common.sh lib/preflight.sh. Expected: PASS and exit 0; test logs show zero mutating calls.
- [ ] **Step 5: Commit.** git add setup.sh lib/common.sh lib/preflight.sh tests/unit/preflight.bats tests/unit/setup_cli.bats; git commit -m "feat: add read-only workstation preflight and preview"

### Task 3: Durable run journal, backups and atomic owned writes

**Files:** Create lib/manifest.py, lib/backup.sh, tests/unit/test_manifest.py and tests/unit/backup.bats.

**Interfaces:** begin_run prints RUN_ID; snapshot_file RUN_ID MODULE PATH creates a durable mode-0700 backup before modification; install_owned_file RUN_ID MODULE SOURCE TARGET records intended SHA-256, atomically replaces via same-directory temporary file and records applied SHA-256. manifest.py init/append/list/verify validates JSONL events and fsyncs each append. Root targets use sudo only after setup confirmation.

- [ ] **Step 1: Write failing tests.** Assert a preexisting file's bytes, owner and mode survive in backup; absent targets are recorded as creations; malformed paths and symlinks are refused; unchanged content makes no new write; manifest intent is durable before a simulated interrupted write; secrets appear neither in log output nor journal values.
- [ ] **Step 2: Run tests red.** Run: python3 tests/unit/test_manifest.py && bats tests/unit/backup.bats. Expected: FAIL for missing helpers.
- [ ] **Step 3: Implement the minimal journal and file primitives.** Keep JSON parsing in the Python standard library. Use exclusive run-directory creation, same-directory atomic replace, sha256sum, cp -a or equivalent metadata preservation, fsync and mode-0700 backup directories. Record path and checksums, never file content.
- [ ] **Step 4: Verify green and interruption safety.** Run the Step 2 command, then bash -n lib/backup.sh. Expected: PASS; interrupted mutation leaves either the old file or the complete new file plus a recoverable journal intent.
- [ ] **Step 5: Commit.** git add lib/manifest.py lib/backup.sh tests/unit/test_manifest.py tests/unit/backup.bats; git commit -m "feat: journal and back up owned workstation changes"

### Task 4: Conservative rollback before any host module

**Files:** Create lib/rollback.sh, bin/dev-rollback and tests/unit/rollback.bats.

**Interfaces:** rollback_preview RUN_ID prints actions and conflicts without writes. rollback_apply RUN_ID restores only when current checksum equals the journaled post-write checksum, deletes only owned new files, and restores recorded service state. Package removal is proposed only for packages installed by this run and is never automatic if dependency ownership is uncertain.

- [ ] **Step 1: Write failing tests.** Assert --list and --dry-run are read-only; owned file restores bytes/mode/owner; later user edits cause safe skip/error; newly created owned file is removed only when unchanged; repeated rollback is harmless; interrupted intent has an exact manual recovery path; unknown run IDs and malformed journal entries fail safely.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/rollback.bats. Expected: FAIL because rollback interfaces do not exist.
- [ ] **Step 3: Implement preview and confirmed apply.** Parse journal with manifest.py, process operations in reverse order, compare checksums before writes, prompt unless explicit confirmed invocation, and never source journal data. Preserve a rollback event trail.
- [ ] **Step 4: Verify green.** Run: bats tests/unit/rollback.bats && bash -n lib/rollback.sh bin/dev-rollback. Expected: PASS. A mismatched checksum test must leave the edited file unchanged.
- [ ] **Step 5: Commit.** git add lib/rollback.sh bin/dev-rollback tests/unit/rollback.bats; git commit -m "feat: add checksum-safe workstation rollback"

### Task 5: Fail-closed cgroup profiles and gated workload launch

**Files:** Create config/profiles.conf, bin/dev-run, bin/dev-gate, tests/unit/dev_run.bats and tests/integration/cgroup.bats.

**Interfaces:** dev-run PROFILE COMMAND [ARGS...] reads a data-only tab-separated profile row; dev-gate waits in a private mode-0700 XDG_RUNTIME_DIR control directory inside a uniquely named systemd --user --scope unit. Parent receives gate PID, checks unit ControlGroup, ActiveState and requested properties, matches /proc/PID/cgroup, then checks cpu.max, memory.high, memory.max, memory.swap.max and pids.max numerically before releasing gate to exec the original argv. The parent handles timeout, exit code, SIGINT/SIGTERM and cleanup. A mode-0600 user profile may override future launches only after validation; never source it as shell code.

- [ ] **Step 1: Write failing tests.** Assert balanced rows equal 800/7/9/2/1024, 400/5/6/1/512 and 600/6/8/2/768 in percent/GiB/task units; a nominal 24-GB/16-thread host with at least 22 GiB reported MemTotal retains those values, smaller RAM/thread counts scale them down without increasing any ceiling, and an emulator whose adapted RAM cap cannot support a 3-GiB guest refuses launch; argv and exit 0/7/signals survive; the sentinel payload does not start on missing user manager, missing or unbounded controller, insufficient CPU ratio, wrong PID membership, scope disappearance, timeout or interrupted handshake; DEV_LIMITS_DISABLED=1 prints a warning and is never inferred.
- [ ] **Step 2: Run unit tests red.** Run: bats tests/unit/dev_run.bats. Expected: FAIL for absent gate/launcher.
- [ ] **Step 3: Implement gate and strict verification.** Start systemd-run --user --scope in the background with a blocked helper and finite timeout. Retain the table at reported MemTotal of at least 22 GiB; below that, scale each RAM/swap ceiling by MemTotal/22 GiB, rounding down to MiB while keeping MemoryHigh below MemoryMax. Cap CPU quota at the lesser of the profile value and max(1, online threads minus 2) times 100%. Reject an invalid adapted profile rather than run unbounded. Parse kernel values as integers and compare limits at least as strict as the resulting row. Release by private local IPC only after all checks; ordinary child processes inherit the scope. Kill/collect a failed scope and remove IPC resources without releasing the payload.
- [ ] **Step 4: Verify green before Task 6.** Run: bats tests/unit/dev_run.bats && bash -n bin/dev-run bin/dev-gate. Expected: PASS. In a disposable systemd VM, run bats tests/integration/cgroup.bats now; expected: live kernel values and payload/child membership match, and swap exhaustion stays in scope. Do not start any persistent host-mutation task until this VM test passes. A container-only pass does not satisfy this gate.
- [ ] **Step 5: Commit.** git add config/profiles.conf bin/dev-run bin/dev-gate tests/unit/dev_run.bats tests/integration/cgroup.bats; git commit -m "feat: gate workloads on effective cgroup limits"

### Task 6: Package planning and pre-install conflict barrier

**Files:** Create lib/packages.sh, tests/unit/packages.bats and tests/integration/packages.bats; extend lib/preflight.sh and setup.sh.

**Interfaces:** apt_plan MODULE PACKAGE... returns a simulated transaction and missing-package list without refreshing indexes. apt_apply RUN_ID MODULE PACKAGE... is callable only after completed preflight, preview and confirmation, journals preinstalled versions/service states, then runs APT. A memory-manager conflict or unknown state blocks that component before APT. Docker CE versus distro provider conflicts are reported.

- [ ] **Step 1: Write failing tests.** Stub APT and systemctl: baseline packages exclude zram-tools and earlyoom; active zram manager or conflicting unit prevents even an apt install call; --zram and --earlyoom remain off by default; Docker CE is not replaced by docker.io; apt simulation failures and missing network stop cleanly; repeated installation with packages already present is a no-op.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/packages.bats. Expected: FAIL for missing package planner/barrier.
- [ ] **Step 3: Implement conflict-first selection and audited apply.** Resolve provider names on Noble, simulate the transaction without mutation, recheck conflicts just before applying, journal package versions and service states, and account for maintainer-script service activation. Never install a memory-manager package as a side effect of baseline selection.
- [ ] **Step 4: Verify green.** Run: bats tests/unit/packages.bats && bash -n lib/packages.sh. Expected: PASS and no mutating stub call in conflict tests. Defer live APT and interruption injection to the disposable VM task.
- [ ] **Step 5: Commit.** git add lib/packages.sh lib/preflight.sh setup.sh tests/unit/packages.bats tests/integration/packages.bats; git commit -m "feat: block conflicting packages before installation"

### Task 7: Opt-in memory manager, OOM policy and sysctl changes

**Files:** Create lib/memory.sh, tests/unit/memory.bats and tests/integration/memory.bats; extend setup.sh, lib/packages.sh and lib/rollback.sh.

**Interfaces:** memory_plan reads preflight facts and selected flags. memory_apply RUN_ID performs an approved --zram, --earlyoom or --swappiness action through the journaled file/service primitives. No memory-manager package or service action occurs when detection is conflicting or indeterminate. vm.page-cluster is never changed.

- [ ] **Step 1: Write failing tests.** Assert default preserves all swap/zram devices, swap priority, earlyoom/systemd-oomd and VM sysctls; --zram proposes LZ4, 50% logical RAM and priority 100 only when no manager exists; active zram-config, zramswap, generator or conflicting unit blocks package install; a new package cannot start its service before approved configuration; missing disk swap warns without creating one; --earlyoom refuses an existing OOM handler; --swappiness requires active compatible zram and explicit selection; repeated apply does not restart unchanged services.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/memory.bats. Expected: FAIL for absent memory module.
- [ ] **Step 3: Implement opt-in plan/apply.** Recheck conflicts immediately before APT. For a newly approved manager, journal and apply a temporary systemd runtime mask for its known unit before package installation; write the approved configuration while masked, then unmask/start only that unit and verify it. Restore the prior mask state on failure. If the package or unit behavior cannot be established safely in the VM, fail before APT and provide manual instructions. Snapshot selected configuration and service states, verify zramctl/swapon or earlyoom state, and roll back a partially failed component safely. Never call swapoff, rewrite fstab or alter page-cluster.
- [ ] **Step 4: Verify green.** Run: bats tests/unit/memory.bats && bash -n lib/memory.sh. Expected: PASS. Later in a disposable VM run bats tests/integration/memory.bats; expected: default state unchanged, approved zram matches 50%/LZ4/priority, conflict branch makes zero package/service changes, interrupted apply is recoverable.
- [ ] **Step 5: Commit.** git add lib/memory.sh lib/packages.sh lib/rollback.sh setup.sh tests/unit/memory.bats tests/integration/memory.bats; git commit -m "feat: add opt-in conflict-safe memory configuration"

### Task 8: Signed, pinned mise installation and idempotent shell activation

**Files:** Create lib/mise.sh, config/mise-release.conf, tests/unit/mise.bats and tests/fixtures/mise-signature/README.md; extend lib/backup.sh and lib/packages.sh.

**Interfaces:** mise_plan reports an existing binary and its owner/path, or the pinned release v2026.10.18. mise_apply RUN_ID downloads only mise-v2026.10.18-linux-x64, SHASUMS256.txt and SHASUMS256.txt.minisig from https://github.com/jdx/mise/releases/download/v2026.10.18/, verifies the signature against the pinned minisign public key from the spec, then verifies the asset hash from the signed manifest. Activation updates Bash and existing Zsh startup files through owned, backed-up blocks. No remote script is executed.

- [ ] **Step 1: Write failing tests.** Assert existing mise is reused and never overwritten; missing minisign, signature, signed checksum entry, artifact or network causes no binary execution/install and prints manual instructions; a changed byte fails hash verification; installation records version/digest; a second run adds no duplicate Bash/Zsh hook; a temporary fresh login shell resolves the intended executable.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/mise.bats. Expected: FAIL for missing module and verification path.
- [ ] **Step 3: Implement minimal verified artifact flow.** Use a private temporary directory, official v2026.10.18 release URLs, distribution-packaged minisign selected only when mise is absent, pinned public key RWTC3g8W3z4RZK3V3qv7fa1QY4JEWyBtqIHW+85QlJpZc5yG+uNYNBSZ, a signed-manifest check and sha256sum check before an atomic user-bin install. Capture the release digest in the run journal. Fixture README explains stubbed verifier outcomes; do not invent an upstream signature. If artifact availability or trust check fails, fail the module without fallback execution.
- [ ] **Step 4: Verify green.** Run: bats tests/unit/mise.bats && bash -n lib/mise.sh. Expected: PASS for stubbed acceptance and refusal cases. In a network-enabled disposable VM only, repeat against the pinned official release; expected: the real signature and hash validate before mise --version, and failed verification leaves the old path unchanged.
- [ ] **Step 5: Commit.** git add lib/mise.sh config/mise-release.conf lib/backup.sh lib/packages.sh tests/unit/mise.bats tests/fixtures/mise-signature/README.md; git commit -m "feat: verify pinned mise release before installation"

### Task 9: Project-level Gradle guidance and separate global opt-in

**Files:** Create lib/gradle.sh, tests/unit/gradle.bats and docs/GRADLE.md; extend setup.sh and lib/rollback.sh.

**Interfaces:** gradle_plan prints per-project or per-invocation recommendations without writing a project. gradle_global_apply RUN_ID resolves GRADLE_USER_HOME or HOME/.gradle, reports existing same-key conflicts, and writes one delimited managed block only after --gradle-global plus separate preview/consent. Suggested opt-in values are -Xmx3g, MaxMetaspaceSize=768m, workers.max=4, caching=true and daemon.idletimeout=900000; parallel and configuration cache stay project-specific.

- [x] **Step 1: Write failing tests.** Assert default and --yes alone never write Gradle files; a nondefault GRADLE_USER_HOME is honored; existing unrelated properties and permissions survive; same-key conflicts outside the block refuse to shadow; identical second run is a no-op; later user edit blocks rollback; project files are never edited.
- [x] **Step 2: Run tests red.** Run: bats tests/unit/gradle.bats. Expected: FAIL for missing module.
- [x] **Step 3: Implement guidance and optional managed block.** Use backup/atomic-write primitives, preserve existing content exactly outside markers, and omit global parallel/configuration-cache settings. Document Gradle property precedence and that 3 GiB JVM heap is not the total build memory.
- [x] **Step 4: Verify green.** Run: bats tests/unit/gradle.bats && bash -n lib/gradle.sh. Expected: PASS; default test shows zero Gradle writes and opt-in test shows exactly one managed block.
- [x] **Step 5: Commit.** git add lib/gradle.sh lib/rollback.sh setup.sh tests/unit/gradle.bats docs/GRADLE.md; git commit -m "feat: provide opt-in Gradle settings without global defaults"

### Task 10: Scoped build command and Gradle daemon boundary

**Files:** Create bin/dev-build, tests/unit/dev_build.bats and tests/integration/gradle_scope.bats; extend docs/GRADLE.md.

**Interfaces:** dev-build COMMAND [ARGS...] sets workload-local Go/Rust/CMake concurrency defaults only if absent, then calls dev-run build with original argv. The supported Gradle isolation recipe is dev-build ./gradlew assembleDebug --no-daemon. The wrapper never asserts that an already running Gradle daemon or Android Studio build joined its scope.

- [x] **Step 1: Write failing tests.** Assert spaces and argument boundaries, exit status 0/7 and signals propagate; user-set concurrency variables win; no global environment or project file is changed; the documented Gradle command includes --no-daemon; an existing reusable daemon case is reported as outside the isolation guarantee.
- [x] **Step 2: Run unit tests red.** Run: bats tests/unit/dev_build.bats. Expected: FAIL for absent wrapper.
- [x] **Step 3: Implement the thin wrapper.** Preserve argv with arrays/exec, set only absent workload-local variables, and keep Gradle advice in documentation instead of silently rewriting project or global properties.
- [x] **Step 4: Verify green.** Run: bats tests/unit/dev_build.bats && bash -n bin/dev-build. Expected: PASS. In a disposable systemd VM run bats tests/integration/gradle_scope.bats against a small fixture project; expected: --no-daemon creates a single-use daemon if needed, and any daemon, Kotlin/compiler process and worker used by this test remains in the verified build cgroup. A deliberately reused preexisting daemon must be detected and excluded from the guarantee.
- [x] **Step 5: Commit.** git add bin/dev-build tests/unit/dev_build.bats tests/integration/gradle_scope.bats docs/GRADLE.md; git commit -m "feat: add scoped build wrapper and Gradle isolation checks"

### Task 11: KVM diagnostics and fail-fast Android Emulator wrapper

**Files:** Create lib/virtualization.sh, bin/dev-emulator, tests/unit/virtualization.bats, tests/unit/dev_emulator.bats and tests/integration/emulator.bats.

**Interfaces:** virtualization_check reports SVM, /dev/kvm access, kvm-ok and emulator -accel-check when available. dev-emulator --list lists AVDs without launching. dev-emulator NAME [ARGS...] verifies an x86_64 system image, KVM readiness and allowed args, then invokes dev-run emulator with -avd NAME -accel on -memory 3072 -cores 4 -gpu auto -no-boot-anim. Host limits remain the independent emulator profile: 400% CPU, 5/6 GiB RAM high/max, 1 GiB swap and 512 tasks.

- [x] **Step 1: Write failing tests.** Assert absent SDK/emulator, absent or inaccessible /dev/kvm, failed -accel-check, missing AVD, ARM-only AVD and acceleration-disabling arguments stop before dev-run; --list remains read-only; a valid x86_64 AVD passes forced -accel on and GPU auto; permitted GPU fallback options do not disable KVM; argv stays intact.
- [x] **Step 2: Run unit tests red.** Run: bats tests/unit/virtualization.bats tests/unit/dev_emulator.bats. Expected: FAIL for missing implementations.
- [x] **Step 3: Implement checks and wrapper.** Resolve the AVD path from the emulator's list and its .ini/config.ini metadata, validate image.sysdir.1 resolves to an installed x86_64 system image under the selected SDK, and leave AVD files unchanged; do not infer readiness from device permissions alone. Reject contradictory guest/acceleration options, call dev-run only after all checks, and report manual BIOS/login steps where needed.
- [ ] **Step 4: Verify green.** Run the Step 2 command and bash -n lib/virtualization.sh bin/dev-emulator. Expected: PASS. In the authorized VAIO acceptance phase, run bats tests/integration/emulator.bats with a user-created x86_64 AVD; expected: KVM actually active, emulator and children in its scope and all five kernel controls enforced. Do not label a VM without nested KVM as a hardware pass.
- [x] **Step 5: Commit.** git add lib/virtualization.sh bin/dev-emulator tests/unit/virtualization.bats tests/unit/dev_emulator.bats tests/integration/emulator.bats; git commit -m "feat: require KVM for scoped Android Emulator launches"

### Task 12: Optional Docker and bounded Compose example

**Files:** Create lib/docker.sh, examples/compose-limits.example.yaml, tests/unit/docker.bats and tests/integration/docker.bats; extend setup.sh and lib/rollback.sh.

**Interfaces:** docker_plan reports distro/CE/rootless state without installing; docker_apply RUN_ID acts only after --docker selection, preview and confirmation. The example starts PostgreSQL and Valkey only on explicit user invocation, binds 127.0.0.1, requires POSTGRES_PASSWORD from the environment and caps CPU, memory and PIDs per service. No docker-group membership change.

- [ ] **Step 1: Write failing tests.** Assert default setup makes no Docker APT/service calls; Docker CE versus distro packages is not mixed; --docker records package/service before state; existing Docker is respected; Compose has localhost binds, bounded cpus/mem_limit/pids_limit and a required password variable but no literal secret; rootless mode with ineffective cgroup controls is warned about.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/docker.bats && yamllint examples/compose-limits.example.yaml. Expected: FAIL because module/example is missing.
- [ ] **Step 3: Implement opt-in package/service handling and minimal example.** Keep containers outside dev-run's claimed budget. Document sudo docker versus rootless and verify actual limits with docker stats only in the opt-in VM test.
- [ ] **Step 4: Verify green.** Run: bats tests/unit/docker.bats && yamllint examples/compose-limits.example.yaml && bash -n lib/docker.sh. Expected: PASS. In a disposable VM with Docker explicitly selected, run bats tests/integration/docker.bats; expected: localhost-only ports and enforced service limits. If Docker is absent, mark NOT INSTALLED rather than PASS.
- [ ] **Step 5: Commit.** git add lib/docker.sh examples/compose-limits.example.yaml setup.sh lib/rollback.sh tests/unit/docker.bats tests/integration/docker.bats; git commit -m "feat: make Docker an explicit bounded option"

### Task 13: Read-only doctor and stable health report

**Files:** Create bin/dev-doctor and tests/unit/dev_doctor.bats; extend lib/preflight.sh.

**Interfaces:** dev-doctor prints Portuguese PASS/WARN/FAIL/NOT INSTALLED and optional --json with stable keys for host, swap, zram, KVM, Mesa, thermal/power, cgroup controllers, Gradle, mise, SDK, Docker and run manifest. It never runs a mutating command.

- [ ] **Step 1: Write failing tests.** Assert doctor does not call sudo/APT or write files, distinguishes not tested from PASS, produces parseable stable JSON and reports VM sysctls without changing them. An unavailable KVM check remains NOT INSTALLED or FAIL with a manual next step.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/dev_doctor.bats. Expected: FAIL for the absent command.
- [ ] **Step 3: Implement read-only reporting.** Reuse preflight facts, query installed tool paths and manifest entries as data, omit secrets and never call a probe that modifies state.
- [ ] **Step 4: Verify green.** Run: bats tests/unit/dev_doctor.bats && bash -n bin/dev-doctor && bin/dev-doctor --json | python3 -m json.tool. Expected: tests PASS, syntax exit 0 and parseable JSON; on a non-Mint development machine, doctor reports unsupported/NOT INSTALLED without modifying it.
- [ ] **Step 5: Commit.** git add bin/dev-doctor lib/preflight.sh tests/unit/dev_doctor.bats; git commit -m "feat: add read-only workstation diagnostics"

### Task 14: Validated user profile selection

**Files:** Create bin/dev-profile and tests/unit/dev_profile.bats; extend config/profiles.conf and bin/dev-run.

**Interfaces:** dev-profile show/select reads the shipped balanced tab-separated table and writes a mode-0600 user-owned profile choice for future scopes. A measured local throughput profile may be selected after validation, but no faster values are pre-populated before VAIO measurements. The current workload scope is never changed.

- [ ] **Step 1: Write failing tests.** Assert balanced remains selected by default; malformed, negative, unbounded, too-large or shell-code-like rows are rejected as data; valid selection affects the next dev-run only; a failed write preserves the prior choice; running scopes are unaffected.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/dev_profile.bats. Expected: FAIL for absent profile CLI.
- [ ] **Step 3: Implement strict parse and atomic user choice.** Use the same validated row reader as dev-run, never source profile content, require explicit selection and show effective provisional limits before launch.
- [ ] **Step 4: Verify green.** Run: bats tests/unit/dev_profile.bats tests/unit/dev_run.bats && bash -n bin/dev-profile bin/dev-run. Expected: PASS and no elevated command.
- [ ] **Step 5: Commit.** git add bin/dev-profile bin/dev-run config/profiles.conf tests/unit/dev_profile.bats; git commit -m "feat: validate selectable workload profiles"

### Task 15: Idempotent user wrapper installation

**Files:** Create lib/install-wrappers.sh and tests/unit/install_wrappers.bats; extend lib/backup.sh and lib/rollback.sh.

**Interfaces:** install_wrappers RUN_ID copies only the owned bin commands to HOME/.local/bin, skipping identical files, snapshotting an existing target and recording its checksum. Rollback removes or restores only an unchanged owned wrapper.

- [ ] **Step 1: Write failing tests.** Assert install creates executable commands and a user-bin PATH hook once; second install is a no-op; an existing foreign executable or later user-modified wrapper is not silently overwritten; interrupted copy retains old or complete new content and rollback metadata.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/install_wrappers.bats. Expected: FAIL for absent installer.
- [ ] **Step 3: Implement journaled user-bin installation.** Reuse owned-file primitives, compare checksums before replacing, and preserve an existing PATH entry and shell content outside a delimited owned block.
- [ ] **Step 4: Verify green.** Run: bats tests/unit/install_wrappers.bats && bash -n lib/install-wrappers.sh. Expected: PASS; duplicate-run test shows one PATH block and no content change.
- [ ] **Step 5: Commit.** git add lib/install-wrappers.sh lib/backup.sh lib/rollback.sh tests/unit/install_wrappers.bats; git commit -m "feat: install workstation commands idempotently"

### Task 16: Connect setup modules without weakening the safety order

**Files:** Modify setup.sh, lib/common.sh, lib/backup.sh and lib/rollback.sh; create tests/unit/setup_flow.bats and tests/integration/setup_vm.bats.

**Interfaces:** setup flow is preflight -> all conflict checks -> selected-module preview -> explicit confirmation -> begin_run -> module apply -> per-module verification -> final manifest/doctor report. --yes confirms only already selected, previewed operations; --gradle-global still needs its separate selection and collision decision. A failed module stops later modules, records the failure, attempts only safe owned recovery and prints the run ID/manual recovery path.

- [ ] **Step 1: Write failing tests.** Assert no APT/service action precedes conflict checks or run journal; --check/--dry-run remain read-only; repeated setup produces no duplicate hooks or service restarts; sudo denial, network failure, interrupted package transaction and low disk space stop with a run ID and intact prior files; unknown flags exit 2; unexpected hardware adapts limits or refuses before launch.
- [ ] **Step 2: Run tests red.** Run: bats tests/unit/setup_flow.bats. Expected: FAIL because module orchestration is not connected.
- [ ] **Step 3: Wire modules in approved dependency order.** Keep sourcing mutation-free, use traps for interrupted runs, compare-before-write, and do not substitute a normal unbounded command when a limited command fails.
- [ ] **Step 4: Verify green.** Run: bats tests/unit/setup_flow.bats tests/unit/setup_cli.bats && bash -n setup.sh. Expected: PASS. In a disposable VM snapshot only, run bats tests/integration/setup_vm.bats; expected: two runs show one managed block and no unintended second-run change, while rollback restores owned configuration and refuses edited-file clobbering.
- [ ] **Step 5: Commit.** git add setup.sh lib/common.sh lib/backup.sh lib/rollback.sh tests/unit/setup_flow.bats tests/integration/setup_vm.bats; git commit -m "feat: orchestrate idempotent workstation setup"

### Task 17: Documentation, static quality and disposable-VM verification

**Files:** Modify README.md; create docs/USAGE.md, docs/PERFORMANCE.md, docs/TROUBLESHOOTING.md, tests/unit/docs_contract.bats, tests/integration/run-vm.sh and tests/README.md.

**Interfaces:** Root README becomes v2 documentation only after code and host-independent tests pass. USAGE explains each opt-in, KVM setup, signed mise, project-level Gradle, --no-daemon, wrapper boundaries and rollback. PERFORMANCE defines baseline and repeated comparison. run-vm.sh refuses execution unless systemd-detect-virt --vm succeeds and VAIO_TEST_VM=1 was deliberately set.

- [ ] **Step 1: Write failing documentation/static checks.** Add tests that README flags match setup --help, every persistent module names rollback behavior, technical docs are English, legacy README remains unchanged, Docker/zram/earlyoom/global Gradle/sysctls are documented default-off, and no prose promises IDE/daemon containment or speed gains without measurement.
- [ ] **Step 2: Run checks red.** Run: bats tests/unit/docs_contract.bats, bash -n setup.sh lib/*.sh bin/* tests/integration/run-vm.sh, shellcheck setup.sh lib/*.sh bin/*, shfmt -d setup.sh lib/*.sh bin/*, and yamllint examples/compose-limits.example.yaml. Expected: documentation test FAIL until docs are written; syntax/static tools may reveal issues to fix in owned files.
- [ ] **Step 3: Write exact operator docs and VM runner.** Include --check/--dry-run, permission prompts, package/service conflict behavior, signed artifact key, manual Studio/AVD setup, rootless Docker caveat, version diagnostics, manifest IDs, checksum-conflict rollback and limits of package reversal. run-vm.sh uses a disposable snapshot, never silently runs on the physical VAIO.
- [ ] **Step 4: Verify green and run the full VM suite.** Run the Step 2 commands plus bats tests/unit/*.bats, python3 tests/unit/test_manifest.py and, inside the disposable VM, VAIO_TEST_VM=1 bash tests/integration/run-vm.sh. Expected: all unit/static/integration checks PASS; scope and swap tests inspect live kernel files; unsupported or absent KVM is reported separately, not counted as hardware success.
- [ ] **Step 5: Commit.** git add README.md docs/USAGE.md docs/PERFORMANCE.md docs/TROUBLESHOOTING.md tests/README.md tests/unit/docs_contract.bats tests/integration/run-vm.sh; git commit -m "docs: document safe workstation setup and VM validation"

### Task 18: Physical VAIO acceptance handoff and measurement gate

**Files:** Extend docs/PERFORMANCE.md and docs/TROUBLESHOOTING.md; create tests/acceptance/vaio-checklist.md. No installer code.

**Interfaces:** This is a runbook for a separate, explicitly authorized physical installation. It first captures an untuned baseline, then records selected installation modules and runs the exact AC-01 through AC-12 checks. A 30-minute representative workload includes Android Studio, one x86_64 AVD via dev-emulator, dev-build ./gradlew assembleDebug --no-daemon and bounded Docker only if opted in.

- [ ] **Step 1: Write the acceptance checklist before claiming success.** Specify baseline and three comparable runs with build/boot medians, peak RAM/swap, per-scope cpu.max/memory.high/memory.max/memory.swap.max/pids.max, memory.events and memory.swap.events, host MemAvailable, swap/zram, PSI, thermals and repeatable interactive-latency samples. Include GUI survival, no host-wide OOM, KVM actually on, scope membership of emulator/Gradle daemon/compilers/workers, and rollback from a changed file plus conflict case.
- [ ] **Step 2: Review the checklist against AC-01 through AC-12.** Expected: every criterion has an evidence line and a PASS/WARN/FAIL/NOT INSTALLED outcome; unavailable measurements are not called passing.
- [ ] **Step 3: Document calibration decisions.** Keep 9/2 GiB build, 6/1 GiB emulator and 8/2 GiB heavy RAM/swap caps as provisional until data justify one-at-a-time changes. Explain that IDE, Docker and preexisting daemons use separate budgets and that no sustained-performance improvement is claimed without comparable repeated measurements.
- [ ] **Step 4: Verify documents only.** Run: sha256sum -c tests/fixtures/legacy.sha256 and bats tests/unit/docs_contract.bats. Expected: PASS. Do not execute setup, an emulator, a memory-pressure test or a host tune as part of this planning task.
- [ ] **Step 5: Commit after implementation approval.** git add docs/PERFORMANCE.md docs/TROUBLESHOOTING.md tests/acceptance/vaio-checklist.md; git commit -m "docs: define physical VAIO acceptance evidence"

## Execution gates

1. The owner reviews and explicitly approves this plan before any implementation code is written.
2. During implementation, complete Tasks 1–5 and their tests before implementing persistent host-mutation paths. Complete journal and rollback tests before VM APT or memory-manager tests.
3. Run privileged installation, interruption, swap-pressure and cgroup integration only inside a disposable VM snapshot. A container pass is not a systemd/KVM pass.
4. Do not run the installer or acceptance workload on the physical VAIO until separate deliberate authorization. Record baseline before any authorized tuning.
5. A failing static/unit/VM gate stops delivery. Manual hardware checks remain NOT TESTED until performed; performance claims require the recorded comparison.

## Final verification commands for the implementer

    bash -n setup.sh lib/*.sh bin/*
    shellcheck setup.sh lib/*.sh bin/*
    shfmt -d setup.sh lib/*.sh bin/*
    bats tests/unit/*.bats
    python3 tests/unit/test_manifest.py
    yamllint examples/compose-limits.example.yaml
    sha256sum -c tests/fixtures/legacy.sha256

Expected: all commands exit 0. In a disposable VM snapshot only:

    VAIO_TEST_VM=1 bash tests/integration/run-vm.sh

Expected: live package, rollback, systemd controller, swap and Gradle-scope tests PASS; KVM hardware acceptance remains separate unless nested KVM is actually available.

## Self-review against approved Revision 3

- **Coverage:** FR-00 through FR-10 and AC-01 through AC-12 map to owning tasks above. Legacy behavior, safe preview, rollback, memory/swap, KVM, Gradle, mise, Docker, diagnostics, documentation and measured concurrency each have explicit checks.
- **Safety order:** Tasks 1–5 establish characterization, read-only behavior, the journal, rollback and a live VM-verified fail-closed scope before any persistent mutation module. VM setup and pressure tests stay separate from physical VAIO acceptance.
- **Interface consistency:** setup calls the named preflight, journal, rollback, package and module functions; dev-build and dev-emulator call dev-run; dev-profile writes only validated future-launch data. Journal and profile files are parsed as data, never sourced.
- **Review focus:** Each of the five listed failure classes has a test in its owning task. Each code task has a red-green cycle; Task 1 records the baseline and Task 18 is a documentation-only acceptance checklist. Every task has five checkable steps and an English Conventional Commit.
- **Proportion:** Optional unattended Android Studio/SDK installation and dev-benchmark are omitted. The design's performance claim remains an evidence gate, and initial ceilings stay provisional.

## Handoff

Implementation approval does not by itself authorize running setup on the physical laptop. Choose the execution method only after the owner reviews this plan.
