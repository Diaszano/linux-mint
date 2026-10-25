# VAIO FE16 physical acceptance record

This is a blank evidence form, not a report of completed physical tests. No physical VAIO installation, tuning, or acceptance workload has been performed. Run it only after separate explicit authorization for the physical notebook. VM results do not satisfy hardware-dependent checks.

## Run record

| Field | Record |
| --- | --- |
| Date, operator, and authorization reference | |
| OS release, kernel, firmware, and power mode | |
| Repository commit and selected setup modules | |
| Android Studio, SDK, AVD image, Gradle wrapper, Docker/image versions | |
| AC or battery state, display setup, and room conditions | |
| Baseline captured before host changes | |
| Workload start/end and run IDs | |

Use `PASS`, `WARN`, `FAIL`, or `NOT INSTALLED` for every acceptance criterion. Attach command output, file paths, timestamps, and measurements as evidence. `NOT INSTALLED` means the prerequisite was unavailable; it is not a pass. Record deviations and retain failed runs.

## Baseline and comparable runs

Capture an untuned baseline before changing host configuration. Record OS/kernel/firmware, power mode, display, AC/battery state, room conditions, Android Studio and SDK versions, project revision, Gradle wrapper and cache state, AVD image and settings, Docker image versions if selected, RAM, CPU threads, swap, zram, and current limits.

Run the same workload three times for the baseline and three times after an authorized change. Use the same reboot or warm-up procedure. Keep versions, project, AVD, cache policy, display, and power conditions constant; document every difference. Report each run and the median. Do not discard a slow run without recording why.

Each run lasts 30 minutes and includes:

1. Android Studio open with project sync/indexing complete.
2. One x86_64 AVD started by `dev-emulator`; verify `-accel on` and KVM acceleration before timing it.
3. A build started with `dev-build ./gradlew assembleDebug --no-daemon`.
4. Docker only if the Docker module was explicitly enabled; use the bounded example services and record Docker as disabled otherwise.

At start, each minute, workload peak, and end, record build completion and emulator boot-to-ready times; host `MemAvailable`, RAM and swap use, active zram, CPU load/utilization, available thermal/frequency data, and `/proc/pressure/{cpu,memory,io}`. Record each workload cgroup's `cpu.max`, `memory.high`, `memory.max`, `memory.swap.max`, `pids.max`, `memory.events`, and `memory.swap.events`. Record cgroup paths and process membership for the emulator, Gradle single-use daemon, compiler processes, and Gradle workers. Identify any reused daemon or IDE-launched build outside the wrapper scope.

For desktop responsiveness, use the same desktop session and 20 repeatable visible interactions (open the application menu, switch windows, focus the editor). Record each action-to-visible-response latency using a monotonic clock or screen recording, then report median and 95th percentile. Record frozen windows, dropped input, compositor restarts, and OOM events.

## Acceptance criteria

| Criterion | Required evidence | Outcome | Evidence reference / notes |
| --- | --- | --- | --- |
| AC-01 Safe preview | Before/after checksums for tracked configuration, package selection, and service state after `setup.sh --check` and `--dry-run` | | |
| AC-02 Idempotence | Two setup passes in an authorized disposable or physical test environment; managed blocks appear once and second-pass changes are recorded | | |
| AC-03 zram preservation | Existing swap/zram state before and after default setup; explicit zram selection and resulting configuration only if separately authorized | | |
| AC-04 Memory and swap protection | VM pressure evidence plus physical workload `memory.events`, `memory.swap.events`, memory/swap use, and scope boundaries | | |
| AC-05 Fail-closed cgroup gate | Effective `cpu.max`, `memory.high`, `memory.max`, `memory.swap.max`, and `pids.max`; payload membership and missing-controller refusal evidence | | |
| AC-06 KVM readiness | SVM readiness, `kvm-ok`, `emulator -accel-check`, compatible x86_64 AVD, and launch evidence showing `-accel on` | | |
| AC-07 Android use and responsiveness | Three-run build/boot results, 30-minute workload logs, desktop interaction percentiles, thermal/pressure data, GUI survival, and host OOM status | | |
| AC-08 mise trust and behavior | Pinned release signature and checksum verification record, existing-install handling, project-local version precedence, and fresh Bash/Zsh hook check | | |
| AC-09 Docker isolation | Default Docker state; if opted in, bounded Compose configuration, loopback bindings, container cgroup limits, and effective runtime evidence | | |
| AC-10 Rollback integrity | Manifest and backup evidence; clean owned-file restore and edited-file conflict preservation; interrupted-install recovery evidence from VM tests | | |
| AC-11 Failure paths | Unsupported OS, package/service conflicts, missing KVM/AVD/SDK, ineffective cgroup controllers, interrupted install, and swap exhaustion test references | | |
| AC-12 Documentation consistency | README, usage, troubleshooting, performance, and rollback instructions agree with selected modules and observed behavior | | |

## Calibration decision

The initial limits are provisional: build 9 GiB RAM / 2 GiB swap, emulator 6 GiB / 1 GiB, and heavy 8 GiB / 2 GiB. They are per-workload ceilings, not reserved memory. Android Studio, Docker, and pre-existing daemons have separate budgets. Change one limit at a time only after reviewing all three comparable runs; retain the more conservative setting when results are inconclusive or desktop responsiveness worsens. Do not claim a performance improvement without the recorded comparison.

`earlyoom` remains unavailable and fail-closed until the approved build-first kill priority can be safely enforced and verified. Record it as `WARN` while unavailable, never `PASS`. Preserve existing swap and zram unless a separate migration is explicitly approved. Record unresolved hardware-dependent checks as `NOT INSTALLED` or `WARN`, not `PASS`.
