# Task 16 Setup Flow Review Fixes

## Changes

- Docker package and dependency revalidation now runs only for the previewed `install` action. A `preserve` action retains its previewed provider/action/package set and returns without invoking the Docker apply path, so baseline APT preview state is not misattributed to Docker and existing Docker service/package state is not modified.
- A selected Docker `manual` action is rejected in conflict planning before the run journal or any selected module apply can start.
- The post-journal, pre-apply free-space guard checks `/`, `$HOME`, and `/var/cache/apt/archives` (falling back to `/var` if the archive path does not exist), requiring at least 1 GiB on each target filesystem.
- Docker verification accepts the explicitly preserved state without requiring an inactive existing Docker service to be started.
- The setup-flow fake APT now returns a stable nonempty `Inst bash (5.2)` transaction, can introduce a distinct later `Inst curl (8.0)` dependency for the dependency-growth test, and records successfully installed packages so the baseline apply path is modeled accurately.
- `earlyoom` remains fail-closed. No legacy files were modified.

## TDD Evidence

With the final setup-flow fixture and the pre-fix `setup.sh`, the preserved-Docker regression fails after the baseline APT apply with:

```text
Error: The Docker package or dependency set grew after preview; re-run setup and review it.
```

The fixed setup flow passes the same case: baseline is verified, Docker reports that its existing provider and service were preserved, and Docker verification completes without a Docker package or service mutation.

The manual-action test confirms failure before run-journal creation, with no package apply or service mutation. The root-space test gives `/` less than 1 GiB while HOME and the APT archive filesystem have space; setup reports a run ID, records its failure, does not apply packages or services, and preserves the prior `.bashrc` contents.

## Verification

All tests ran sequentially inside the disposable Ubuntu Noble VM. No setup or host-tuning command ran on the physical VAIO FE16.

- Focused `setup_flow.bats` and `setup_cli.bats`: 26 passed, 0 failed.
- Full unit Bats suite: 206 passed, 0 failed.
- Python manifest tests: 20 passed.
- VM-gated integration Bats: 19 total, 15 passed, 0 failed, 4 skipped. Docker integration skipped because Docker is absent; three Gradle scope tests skipped because Gradle is absent.
- `bash -n setup.sh lib/*.sh bin/* tests/integration/*.bats`: passed.
- `shellcheck -x -S warning setup.sh lib/*.sh bin/*`: passed with no warning-level findings.
- `shfmt -d -i 2 setup.sh`: passed. Full-tree shfmt still reports pre-existing differences in unmodified shell files; no unrelated formatting was applied.
- `yamllint examples/compose-limits.example.yaml`: passed.
- `sha256sum -c tests/fixtures/legacy.sha256`: all legacy hashes passed.
- `git diff --check`: passed.

## Limits

The four integration skips leave Docker and Gradle runtime integration unverified in this VM. Physical VAIO acceptance remains unauthorized and unperformed. Full-tree shfmt has existing formatting differences in files outside this fix's scope.
