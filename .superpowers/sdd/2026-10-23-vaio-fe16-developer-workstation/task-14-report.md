# Task 14: Validated user profile selection

## Contract clarification
The selectable preset remains `balanced` only. `dev-run` workload names remain `build`, `emulator`, and `heavy`; user workload tables must define all three rows. `dev-profile show` previews provisional limits, while `dev-profile select balanced` writes the preference for future scopes. No faster or throughput profile is exposed without physical VAIO measurements and separate approval. The shared validated row reader is used by both profile commands and `dev-run`.

## Implementation
- Parses workload tables as strict data: exact tab count, known workload name, canonical integer syntax, uniqueness, bounds, and all required workloads. Configuration content is never sourced or executed.
- Provides `dev-profile show` and `dev-profile select balanced`. Selection uses a private temporary file and same-directory atomic replacement, requires an owned non-symlink directory and mode-0600 regular choice, and cleans temporary files on failure.
- `dev-run` reads the same table and profile choice. A selected preset affects only new invocations; current scopes are unchanged.
- The `balanced` comment in `config/profiles.conf` identifies limits as provisional without changing per-workload values.
- No privileged commands or host configuration changes were added.

## Review fix: incomplete user tables
The independent review found that a syntactically valid table containing only `build` was accepted. Added a regression with a mode-0600 user table containing only `build`; `dev-profile show` and `select balanced` now reject it with `Malformed, incomplete, or empty workload table`, and the selection test verifies the prior profile file checksum is unchanged. `profile_load_table` requires exactly the presence of `build`, `emulator`, and `heavy`, in addition to existing parsing and bounds checks. Tests that intentionally supplied valid user tables now include all required rows.

## TDD and verification
- RED: in the disposable Noble VM, before the implementation fix, build-only user tables incorrectly passed `show` and `select balanced`; selection replaced the previous profile.
- Focused disposable VM Bats: `bats --show-output-of-passing-tests --print-output-on-failure tests/unit/dev_profile.bats tests/unit/dev_run.bats` — 27/27 passed.
- Full sequential disposable VM Bats unit suite: `bats --tap tests/unit` — 182/182 passed.
- Python unit suite: `python3 -m unittest discover -s tests/unit -p "test_*.py"` — 19/19 passed.
- Disposable VM integration suite: 18 total; 15 passed and 3 environment-skipped (Docker unavailable and Gradle prerequisites unavailable).
- Static checks: Bash syntax, warning-level ShellCheck, `shfmt -d -i 4 lib/profiles.sh bin/dev-run`, `git diff --check`, and all seven legacy fixture hashes passed. `shfmt -d -i 4 bin/dev-profile` reports existing formatting differences in that file; it was not broadly reformatted as part of this targeted fix.
- No legacy files or physical VAIO settings changed. Physical notebook setup, tuning, performance measurements, and acceptance testing were not performed.

## Review status
The review finding is fixed and verification evidence is recorded. A separate independent re-review is still required before Task 14 can be marked complete or dependent tasks continue. The plan references `tests/acceptance/vaio-checklist.md`, which is absent in the repository; record this as a Task 18/acceptance limitation if still applicable rather than adding an unplanned file here.
