# Task 15: User wrapper installation

## Result

Implemented `install_wrappers RUN_ID` in `lib/install-wrappers.sh`. The installer exposes only the supported user commands from `bin/`, excluding internal `dev-gate`. Each installed command is a generated executable launcher that invokes the corresponding source command using a fixed, shell-escaped checkout root and forwards the original argument vector unchanged.

The installer uses the existing journaled owned-file and managed-block functions. Identical launchers and PATH hooks are no-ops. Existing user startup content and PATH entries are preserved. Existing targets are snapshotted and recorded by checksum; rollback uses the existing checksum-safe behavior. User-edited owned targets are not overwritten or removed. The legacy implementation was not modified.

## Verification

All tests ran sequentially in the disposable VM, not on the physical VAIO FE16.

- TDD red: the initial five Bats tests failed because the installer was absent.
- Focused green: `bash -n lib/install-wrappers.sh` and `bats --print-output-on-failure tests/unit/install_wrappers.bats` passed; 6 tests.
- Full unit suite: `bats --print-output-on-failure tests/unit/*.bats` passed; 189 tests, zero failures.
- Manifest suite: `python3 tests/unit/test_manifest.py` passed; 19 tests.
- Static syntax: `bash -n setup.sh lib/*.sh bin/*` passed.
- Formatting: `shfmt -d lib/install-wrappers.sh tests/unit/install_wrappers.bats` passed.

The interruption test injects failure at atomic replacement, checks that the old target bytes remain, and verifies that the journal remains parseable. The foreign-target rollback test confirms restoration, while the modified-target test confirms checksum conflict refusal.

## Limitations

The generated launchers embed the checkout's absolute path. Moving or deleting the checkout requires reinstalling wrappers from its new location. Physical VAIO acceptance and host installation were not run or authorized in this task.
