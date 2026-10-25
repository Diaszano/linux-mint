# Performance measurement protocol

## Status

The shipped build, emulator, and heavy workload ceilings are provisional. There is no physical VAIO FE16 measurement result in this repository, and no performance improvement is claimed. VM test evidence validates behavior in that VM only. It does not establish notebook responsiveness, thermals, sustained clocks, KVM availability, battery life, or application performance on the VAIO.

Initial balanced ceilings for the target 24 GiB / 16-thread system are:

| Profile | CPU quota | `memory.high` | `memory.max` | `memory.swap.max` | `pids.max` |
| --- | ---: | ---: | ---: | ---: | ---: |
| build | 800% | 7 GiB | 9 GiB | 2 GiB | 1024 |
| emulator | 400% | 5 GiB | 6 GiB | 1 GiB | 512 |
| heavy | 600% | 6 GiB | 8 GiB | 2 GiB | 768 |

Limits scale down when detected RAM or available CPU threads are below the target assumptions. They are per-scope ceilings, not reserved capacity. The desktop, Android Studio, Docker, and pre-existing services have separate resource use. These values remain unchanged until repeated measurements justify a documented, one-at-a-time calibration.

## Baseline and comparison procedure

Physical acceptance must be separately authorized. Capture an untuned baseline before changing host configuration. Use the same OS release, firmware/power mode, kernel, Android Studio/SDK, project revision, Gradle wrapper and dependencies, AVD image and guest configuration, Docker image versions, display setup, AC/battery state, and room conditions for baseline and comparison runs. Record differences instead of treating non-identical runs as directly comparable.

Run three comparable repetitions per condition, after the same reboot or warm-up procedure. Report each run and the median; do not drop slow runs without recording a reason. Capture the exact command lines, versions, selected profile, run ID, timestamps, and whether the run was wrapped or direct. Use identical Gradle cache policy in each condition and report whether caches were cold or warm.

The representative concurrent workload lasts 30 minutes and includes:

1. Android Studio open on the same project and performing the same indexing/sync state.
2. One user-created x86_64 Android Virtual Device, launched through `dev-emulator` with KVM acceleration confirmed on.
3. A Gradle build launched with `dev-build ./gradlew assembleDebug --no-daemon`.
4. Docker only when explicitly enabled; use the same bounded Compose services and image versions in all compared Docker runs. Record Docker as disabled when it is not selected.

Record build completion time and emulator boot-to-ready time for each run. At one-minute intervals and at each workload peak, record host `MemAvailable`, used swap, active zram devices, CPU utilization/load, thermal sensors and CPU frequency when available, and `/proc/pressure/{cpu,memory,io}`. Record each workload's effective `cpu.max`, `memory.high`, `memory.max`, `memory.swap.max`, and `pids.max`, plus `memory.events` and `memory.swap.events`. Record cgroup paths and verify emulator, Gradle single-use daemon, compiler processes, and Gradle workers are descendants of the expected scope. Note any IDE build or reused daemon outside that scope.

Measure desktop responsiveness consistently: use the same desktop session and a scripted or recorded set of 20 visible interaction samples, such as opening the application menu, switching windows, and focusing the editor. Record the action-to-visible-response latency with a monotonic clock or screen recording, report median and 95th percentile, and note any frozen window, dropped input, compositor restart, or out-of-memory event. Avoid comparing subjective impressions alone.

## Calibration and reporting

For each repeated run, report build and emulator startup medians, peak RAM and swap, pressure-stall counters, thermal/frequency behavior, desktop response latency, cgroup event counters, and any process that escaped the intended cgroup. Record limit values before and after a calibration. Change one ceiling at a time, rerun the same baseline and concurrent workload three times, and retain the more conservative setting if results are inconclusive or desktop responsiveness worsens.

Do not reduce the desktop safety margin based only on a successful build. `memory.high` is a pressure threshold; `memory.max` and `memory.swap.max` are hard workload bounds. Swap is not disabled globally. If swap exhaustion or cgroup OOM kills occur, preserve logs and the run manifest, stop the comparison, and recalibrate in an authorized test environment before changing a profile. Do not claim faster builds, smoother desktop behavior, or improved sustained performance without the measurements and comparable repeated runs described here.

## Physical acceptance handoff

Use [the VAIO FE16 acceptance checklist](../tests/acceptance/vaio-checklist.md) as a blank evidence record. Physical installation, tuning, and workload measurements require separate explicit authorization. Mark unavailable hardware or prerequisites `NOT INSTALLED`; VM results do not establish notebook responsiveness or performance. Keep all resource ceilings provisional until three comparable runs are recorded, and make no performance claim without their measurements.
