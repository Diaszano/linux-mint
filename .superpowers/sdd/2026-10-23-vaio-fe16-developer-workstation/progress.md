# SDD ledger — plan: docs/superpowers/plans/2026-10-23-vaio-fe16-developer-workstation.md

## Workspace and authority
- Branch: feature/vaio-fe16-workstation (repository began without commits).
- Approved spec: docs/superpowers/specs/2026-10-23-vaio-fe16-developer-workstation-design.md, Revision 3.
- User authorized implementation and automated testing, but explicitly prohibits host settings, setup execution, tuning, or privileged/system-pressure integration outside a disposable VM; physical VAIO acceptance requires separate authorization.
- Legacy tree must remain unchanged.

## Preflight conflict scan
| Task(s) / requirement | Relationship or consistency check | Ruling |
| --- | --- | --- |
| 1 -> 2-18 | Characterization and checksums are the baseline consumed by migration and must be committed before new behavior. | Do Task 1 first; never stage edits in legacy tree. |
| 2 -> 3 -> 4 -> 6-18 | Read-only discovery precedes journal, backups and rollback; package/config mutation depends on durable rollback. | Preserve dependency order; do not add persistent modules before task 4 gates. |
| 3/4 -> 5 -> 10/11 | Verified cgroup controls and process membership underpin all limited workload launchers. | Each launcher must be blocked behind kernel-observed limits; avoid approximating controls. |
| 6 -> 7/8/9/11/12 | Package/service conflict checks precede installs/config; memory manager remains opt-in and existing swap/zram preserved. | Recheck conflict barrier at mutation time; abort safely on unknown/conflicting state. |
| 8/9 -> 10/11 | mise authenticity and project-level Gradle policy feed build/emulator recipes. | No global Gradle defaults; validate pinned release authenticity, --no-daemon, x86_64 and -accel on. |
| 15/16 -> 17/18 | Rollback and idempotency evidence must precede host integration/acceptance. | Privileged integration only in disposable VMs; physical hardware checks remain unexecuted. |
| Global resource limits -> 18 | Spec marks limits provisional pending representative concurrent workload. | Report measurements only from executed workloads; no performance claims without evidence. |

## Decisions / rulings
- Ruling: use a feature branch instead of a worktree because this repository has no commits and worktree creation needs a committed base; the user explicitly permits either. — Cost if wrong: feature branch shares the checkout. — Mitigation: no main/master changes, no merge/push.
- Ruling: run automated non-privileged tests in current checkout; provision a disposable VM before privileged integration. — Cost if wrong: host may lack tools, requiring VM for full suites.

## Task status
- [ ] Tasks 1–18 pending.

## Disposable VM evidence
- QEMU host is an ephemeral Docker container `vaio-fe16-test-vmhost`; guest is Ubuntu Noble 24.04 minimal cloud image, QEMU with KVM, 8 GiB RAM, 4 vCPU; guest root disk is ephemeral and repo is shared read-only via 9p.
- Guest image verified against Ubuntu's official minimal Noble `SHA256SUMS` before conversion/boot. An earlier regular cloud image attempt used a failed filename filter; guest was stopped and discarded before tests. Corrected minimal image check reported `minimal.img: OK`.
- Test prerequisites installed inside guest only. Versions: bats 1.10.0-1; minisign 0.11-1; python3 3.12.3-0ubuntu2.1; shellcheck 0.9.0-1; shfmt 3.8.0-1; yamllint 1.33.0-1.
- Task 1 actual Bats output: `1..6`; `ok 1` through `ok 6`. All seven supplied legacy hashes reported `OK`; legacy script `bash -n` exited 0.
- Host OS has not been modified by the workstation setup. Docker/QEMU VM test infrastructure is disposable; no physical tuning or setup execution performed.

## Task status
- [x] Task 1 complete: implementation, Bats/hash/syntax checks, and independent review passed.
- [ ] Tasks 2–18 pending.

## Task 2 status
- [x] Implementation committed as `6607bf3` (`feat: add read-only workstation preflight and preview`). Tests: Task 2 8/8 and full unit suite 14/14 in the disposable Noble guest; bash -n and ShellCheck pass.
- [x] Independent Task 2 review passed after fix round 1; all five findings addressed.
- Ruling: missing-source RED was performed in a temporary copy inside the guest because the working repo mount is intentionally read-only; two added behavior tests also failed before implementation fixes, then all passed. — The partial first worker's original TDD history was unavailable after usage-limit failure. — Any mismatch in chronology is confined to Task 2's report and can be corrected without changing shipped behavior.
- Task 2 review: FAIL, fix round 1 required. Findings: preserve unknown for failed probes; report swap priorities; discover named and inactive competing units; honor GRADLE_USER_HOME in global Gradle preview; tests must trap mutating systemctl calls. Reviewer confirmed root/platform validation and opt-in defaults; narrow probe reproductions confirmed unknown-as-no behavior.
- Task 2 fix round 1 committed as `09b9c83` (`fix: preserve uncertainty and complete preflight conflict facts`). Report: four added test files paths modified; RED findings exercised; targeted 15/15, full unit 21/21, bash -n and ShellCheck pass. Independent scoped re-review pending.

Task 2 limitation: conflict inventory filters system/user unit names containing `zram`, `swap`, or `oom`; a conflicting manager with an unrelated unit name is not discovered. Independent reviewer considers this an out-of-scope observation; retain for whole-branch review and final report.

- [ ] Task 3 pending.

## Task 3 status
- [x] Implementation committed as `68366ff` (`feat: journal and back up owned workstation changes`). TDD evidence: missing-helper RED; final VM GREEN 13 Python tests + 25 Bats tests, Bash syntax and ShellCheck clean. Uses temp targets only.
- [x] Independent Task 3 review passed after fix round 1; both findings addressed.
- Task 3 independent review: FAIL; fix round 1 required. Confirmed append can poison a journal with an outside backup path, and incomplete initialization makes list abort over healthy recovery runs. Normal backup/fsync ordering and existing coverage otherwise sound.
- Task 3 fix round 1 committed as `56863b7` (`fix: reject invalid journal appends and list healthy runs`). TDD: 2 new failures for foreign backup and incomplete init; final 15 Python + 25 Bats pass, syntax/ShellCheck clean. Scoped re-review pending.

Task 3 minor deferred observation from re-review: an invalidly named entry under the run store can still abort listing because run_path validation is outside the per-run error handler; valid but incomplete runs are skipped with warning. Include in whole-branch review.

- [ ] Task 4 pending.
- Task 4 plan defect / ruling: committed Task 3 schema has only run/snapshot/intent/applied events, with intent/applied limited to file paths and checksums, while Task 4 requires reversible service/package state and a rollback trail. — Extend `lib/manifest.py` minimally with backward-compatible validated metadata-only service/package/rollback records and tests. — Cost if wrong: widening schema can affect replay/validation, mitigated by keeping old event forms unchanged and adding compatibility tests.

- [ ] Task 5 pending.

## Task 4 status
- [x] Implementation committed as `f56b584`; independent review passed. Journal event schema extension was reviewed; no blockers. Task 3 malformed-run listing observation was covered by Task 4 test 41.

## Task 5 status
- [x] Implementation committed as `8652112` (`feat: gate workloads on effective cgroup limits`). Disposable Noble QEMU live cgroup suite passed all 6 integrations; 69 Bats and 15 Python tests, syntax, shfmt, ShellCheck, and legacy hashes pass. Pressure test observed exit 137, one `oom_kill`, and swap peak within 16 MiB limit; cleanup confirmed no temporary swap/IPC/scopes/slices.
- [x] Independent Task 5 review passed after security fix round 1; XDG runtime IPC substitution finding addressed.
- Task 5 review: FAIL, security fix round 1 required. A group/world-writable non-sticky owned XDG_RUNTIME_DIR permits other-UID directory/path substitution of the release IPC; validate safely and add sentinel refusal test before Task 6.

- [ ] Task 6 pending.
- Task 6 review: FAIL, fix round 1 required. Four confirmed blockers: memory-manager package/dependency filters inconsistent, template swapon command discarded, APT_CONFIG stripped by sudo (simulation/install mismatch), and failed post-install inventory recorded as absent. Fix and re-review before Task 7.

## Task 6 status
- [x] Independent review passed after fix rounds 1 and 2. Final package classifier and package/service barrier reviewed; opaque custom launchers remain a disclosed limit. Guest verification: 104 Bats + 15 Python, cgroup/package integrations, syntax, warning-level ShellCheck, shfmt, and legacy hashes pass.
- Task 6 fix round 1 re-review found a new Important regression: `_apt_memory_manager`'s broad `*oom*` catches unrelated `zoom` and `foomatic-db`, falsely blocking earlyoom. Fix round 2 required; use precise known manager names and negative tests.
- Task 6 fix round 2 committed as `a1c9d61`: precise OOM package names replace substring `*oom*`; added positive manager and negative zoom/foomatic tests. Guest suite: 104 Bats + 15 Python; integrations and static checks pass. Scoped re-review pending.

- [ ] Task 7 implementation partial; commits `f05d188`, `ecb2cbc`, and pending fail-closed earlyoom guard. Real zram apply in Noble VM verified active service, LZ4, ~50% RAM, priority 100; rollback refused without stopping active zram. Earlyoom remains unavailable pending a verified build-first kill-priority mechanism.
- Task 7 independent review: FAIL, fix required. Earlyoom lacked an explicit previewed and journaled policy before service start; swappiness did not reject competing sysctl policy before mutation.
- [x] Task 7 review fixes: explicit earlyoom `-m 10,5 -s 10,5` policy, config write while runtime-masked, external sysctl configuration scan during planning and immediately before apply. The Noble package unit/config contract was inspected from its APT-authenticated artifact. Existing systemd-oomd caused real earlyoom apply to fail closed before APT.
- Task 7 second independent review: FAIL, global earlyoom can kill the largest desktop process and cannot guarantee build-first preference. Current fix disables memory/package apply and setup install preview for earlyoom; task remains incomplete. Final guard VM run: 123 Bats and 15 Python tests, plus Bash syntax, memory.sh shfmt, and warning-level ShellCheck pass.
- [x] Review-fix verification in disposable VM: focused memory Bats 16/16, complete Bats 122/122, Python 15/15, Bash syntax, shfmt, ShellCheck warning-level, and git diff checks pass. Report at `task-07-report.md`.
- Task 7 plan-file-map ruling: approved plan omits a narrow root helper for atomic writes to `/etc` while keeping setup normal-user and user-owned journal. Extend Task 7 with standard-library helper fixed to memory-owned paths; content only stdin; no-symlink traversal/checksum compare; user journal intent before and applied after sudo mutation. — Required to satisfy both sudo-per-operation and durable before-write journal guarantees. — Cost if wrong: privileged helper adds attack surface; mitigate fixed allowlist, caller-independent tests, no shell evaluation, checksum/inode checks and disposable-VM integration.

## Task 8 — Secure mise installation

Implemented the pinned, signature- and digest-verified mise release flow, safe exclusive user-bin installation, journaled artifact digest, and backed-up idempotent Bash/Zsh activation. Existing mise binaries are reused. The distro minisign package is conditional on mise being absent. The Task 7 earlyoom fail-closed guard remains unchanged.

File-map ruling: extended `lib/manifest.py` with a backward-compatible artifact journal event containing only pinned release version, URL identity, asset name, and verified SHA256. This was required to satisfy Task 8 release digest journaling; schema and replay behavior have unit coverage.

Verification: disposable VM official release signature/hash/install/login-shell and rollback checks passed; Bats unit+integration suite passed 132 cases; Python manifest suite passed 19 tests; Bash syntax, shfmt, and diff checks passed. An extra disposable VM minisign fallback invocation had truncated output and is not counted as verified. No physical VAIO tests or host changes were performed. See `task-08-report.md` for details.

## Task 9 status
- [x] TDD implementation committed as `b59a172` (`feat: provide opt-in Gradle settings without global defaults`); implementation and review evidence are in `task-09-report.md`.
- [x] Disposable VM verification: focused Gradle/setup Bats 18/18; serialized full Bats 143/143 with exit 0; Python 19/19; Bash syntax, shfmt and warning-level ShellCheck pass.
- [x] Defaults and `--yes` remain read-only. Global edits require `--gradle-global` and the matching token from a fresh preview. The generic manifest rollback already supports these files, so `lib/rollback.sh` did not need a code change.
- Task 9 first independent review found Java-properties continuations can hide a managed key; fixed in `cc2b507`. Regression test failed pre-fix; full serialized VM suite passed (11/11 focused, 144/144 Bats, Python 19/19).
- Task 9 second independent review found a lone-backslash continuation could leave an empty buffer and make the next marker look like a block boundary. Regression test failed pre-fix because preview missed a following conflicting key. Fixed by tracking continuation independently of buffer content. Post-fix: focused Gradle tests passed; complete sequential VM suite passed 145 Bats, Python 19/19, Bash syntax, shfmt, warning-level ShellCheck. Independent re-review passed; no code issue.

## Task 10 status
- [ ] TDD implementation committed pending `feat: add scoped build wrapper and Gradle isolation checks`; Task 7 earlyoom remains partial and fail-closed.
- RED: all four initial unit tests failed with command-not-found before `bin/dev-build` existed. Focused unit suite now has five passing tests for argv, defaults/overrides, exit and signal status, no project writes, and Gradle guidance.
- Disposable Noble VM prerequisites: OpenJDK 17.0.20.1 (`17.0.20.1+1-1~24.04`) and official Gradle 8.14.6 distribution installed only in guest after matching official SHA256 `7988ed071b2a07900e2ec715fca15c6ab72bce6db433af301fa7fa7e9407bd24`.
- Gradle `--no-daemon` integration forced a single-use daemon with different JVM args and verified the daemon, forked javac/Gradle worker, and child PID shared the verified `dev-build-*.scope`; output path `/user.slice/user-1000.slice/user@1000.service/app.slice/dev-build-bUVyogeGNJ-237920.scope`.
- Reuse integration started a persistent daemon outside the wrapper, then verified the task daemon remained outside the new build scope at `/user.slice/user-1000.slice/session-145.scope`. Test cleanup stopped only its own private-home Gradle daemon.
- Full serialized VM suite: `bats tests/unit tests/integration` with Gradle on PATH exited 0, 152 passed, 0 failed; Python unittest 19/19. `bash -n`, `shfmt -d -i 2`, and warning-level ShellCheck passed; host `git diff --check` passed. No physical host changes.
- [x] Task 11 implementation committed as `abc1efd` (`feat: require KVM for scoped Android Emulator launches`); real Android Emulator acceptance is explicitly deferred because the disposable Noble guest has no SDK/AVD and its normal test user cannot access `/dev/kvm`. Physical VAIO acceptance is unauthorized and untested.
- Task 11 TDD RED: focused unit run failed while the virtualization module and wrapper were absent. Final focused disposable Noble VM suite passed 15/15; full serialized unit+integration Bats passed 168/168, Python manifest tests passed 19/19, Bash syntax, shfmt and warning-level ShellCheck passed, and host `git diff --check` passed.
- Unit tests exercise argument assembly with an isolated fake SDK and in-process test overrides for KVM helper functions; production has no environment override for `/dev/kvm`. Actual unprivileged launch was verified to fail closed on inaccessible `/dev/kvm`. No real emulator acceleration claim.
- Task 11 GPU docs are deferred to planned Task 14 docs pass; wrapper defaults to `auto` and permits only `swiftshader` fallback.

## Task 12 status
- [x] Implementation committed as `1ff6281` (`feat: make Docker an explicit bounded option`). Detailed evidence is in `task-12-report.md`.
- TDD RED: Docker tests failed while the module/example were absent; a provider-dependency regression demonstrated acceptance of an unexpected `docker-ce` dependency when no provider existed; an active-orphan-socket regression demonstrated the planner ignored that state. Both safety gaps were fixed and regression tests now pass.
- Focused VM suite: `bats --tap tests/unit/docker.bats tests/unit/setup_cli.bats` passed 18/18. `yamllint`, `bash -n lib/docker.sh lib/packages.sh setup.sh`, and `shellcheck -x lib/docker.sh lib/packages.sh` passed.
- Full serialized clean-overlay Bats: `bats --tap tests/unit` TAP `1..164`, zero failures. `bats --tap tests/integration` TAP `1..18`, 15 passed, 3 skipped because Gradle was not installed in this overlay; zero failures. Prior Task 10 Gradle integration evidence remains recorded above.
- Fresh Noble QEMU Docker install integration passed. Manifest confirmed packages absent→installed and docker.service disabled/inactive→enabled/active; Compose inspection confirmed requested per-service CPU/memory/PID limits and localhost-only bindings. Test containers, volume, and network were removed.
- `dev-rollback --dry-run` restored the Docker service to disabled/inactive in preview and left package removals for manual review. No rollback apply ran.
- Original disposable guest has an active orphan docker.socket (`LoadState=not-found`, empty FragmentPath) after removal of only Docker test packages. It was preserved; current docker_plan fails closed before APT/service actions. No physical VAIO changes or hardware acceptance tests.

## Task 13 status
- [x] Implementation and focused disposable-VM diagnostics tests are complete; detailed verification and environment limitations are in `task-13-report.md`.
- The focused doctor suite passed 6/6. Full sequential unit coverage passed 170 Bats tests plus 19 manifest tests. Full integration coverage reported 18 tests: 15 passed, 3 Gradle tests skipped because Gradle is absent from the disposable overlay guest.
- Static checks and JSON parsing passed in the guest. The named `tests/integration/run-vm.sh` runner is absent, so the repository's actual `tests/integration/*.bats` suite was run directly with `VAIO_TEST_VM=1`.
- No physical notebook installation, tuning, or acceptance tests were performed. KVM, SDK, Gradle, and hardware-specific performance behavior remain unverified.
