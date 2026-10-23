# Test evidence

`legacy_behavior.bats` characterizes the supplied legacy snapshot by inspecting its files. It does not execute setup or workload scripts. The assertions record these observed behaviors: Docker and earlyoom default on; setup writes user Gradle properties and `vm.swappiness=100` / `vm.page-cluster=0`; `--check` exits through the source-tree `bin/dev-doctor` before APT actions; `dev-run` requests CPUQuota, MemoryHigh, MemoryMax and TasksMax without reading kernel limit files; `dev-build` forwards `"$@"`; and the Compose example has service limits and loopback-only port binds.

`tests/fixtures/legacy.sha256` hashes every regular file in the supplied `legacy/vaio-fe16-dev-setup/` snapshot. No checksum for an original ZIP was supplied, so these hashes establish only the current checkout snapshot. Never execute legacy setup for characterization.
