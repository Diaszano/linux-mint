# Task 14: Validated user profile selection

## Contract

The selected preset is `balanced` only until physical VAIO measurements justify another option. Workload names remain `build`, `emulator`, and `heavy`; every user table must contain all three rows. The shared parser is used by both `dev-profile` and `dev-run`, and profile content is never sourced or executed.

`dev-profile show` previews the provisional limits. `dev-profile select balanced` atomically writes a mode-0600 user-owned choice for future scopes only; active scopes are unchanged. Failed writes preserve the previous choice.

The approved file map was extended with `lib/profiles.sh` and `tests/unit/dev_run.bats` so both commands share the same validated row reader and the caller is tested directly.

## Review fixes

The independent review found that a mode-0600 table containing only `build` was accepted by the profile CLI. The parser now requires all three workload names. A follow-up regression verifies `dev-run emulator` rejects the same table before creating a scope or launching its payload.

## Verification

- Focused disposable VM suite: `bats tests/unit/dev_profile.bats tests/unit/dev_run.bats` — 28/28 passed.
- Full sequential disposable VM unit suite: `bats --tap tests/unit` — 183/183 passed.
- Python manifest suite: 19/19 passed.
- Integration suite: 18 total, 14 passed and 4 skipped because Docker and Gradle prerequisites were unavailable.
- `bash -n`, warning-level ShellCheck, `shfmt -d -i 4 lib/profiles.sh bin/dev-run`, legacy fixture hashes (7/7), and `git diff --check` passed.

The selection and parser implementation is committed as `e59dae2`; incomplete-table validation is `1462ddc`. The added `dev-run` regression and plan/report cleanup are a follow-up documentation/test commit.

The independent review passed. The plan references `tests/acceptance/vaio-checklist.md`, which is absent from this checkout; it remains a Task 18 acceptance-documentation limitation. No legacy files or physical VAIO settings were changed. Hardware measurements and physical acceptance remain unperformed.
