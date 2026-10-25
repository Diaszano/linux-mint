#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  [[ $(hostname) == vaio-fe16-test-vm && $(cat /proc/1/comm) == systemd ]] || skip 'Run only in the disposable Noble QEMU VM'
  [[ $(
    . /etc/os-release
    printf '%s' "$VERSION_CODENAME"
  ) == noble ]] || skip 'Requires the disposable Noble guest'
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export ROOT HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export WORK="$BATS_TEST_TMPDIR"
  mkdir -p "$HOME"
  chmod 755 "$WORK" "$(dirname "$WORK")"
}

teardown() {
  if [[ -f $WORK/fixture-created ]]; then
    sudo systemctl disable --now vaio-task6-fixture.service >/dev/null 2>&1 || true
    sudo dpkg --purge vaio-task6-fixture >/dev/null
    sudo systemctl daemon-reload
  fi
  if [[ -f $WORK/manager-created ]]; then
    sudo rm -f /run/systemd/system/vaio-task6-personal.service
    sudo systemctl daemon-reload
  fi
}

@test "real installed-package planning is read-only and no-op" {
  run bash -c 'set -euo pipefail; source "$ROOT/lib/packages.sh"; apt_plan baseline bash; apt_apply unused baseline --confirmed "$APT_PLAN_TOKEN" bash'
  [ "$status" = 0 ]
  [[ "$output" == *missing=none* ]]
  [ ! -e "$XDG_STATE_HOME" ]
}

@test "real unrelated-name unit metadata blocks a memory package before APT" {
  cat >"$WORK/personal.service" <<'UNIT'
[Unit]
Description=Private manager
[Service]
ExecStart=/usr/sbin/zramctl /dev/zram0
UNIT
  sudo install -m 644 "$WORK/personal.service" /run/systemd/system/vaio-task6-personal.service
  touch "$WORK/manager-created"
  sudo systemctl daemon-reload
  mkdir "$WORK/bin"
  cat >"$WORK/bin/apt-get" <<'SH'
#!/bin/sh
touch "$WORK/unexpected-apt"
exit 99
SH
  chmod +x "$WORK/bin/apt-get"
  run env PATH="$WORK/bin:$PATH" bash -c 'source "$ROOT/lib/packages.sh"; apt_plan zram zram-tools'
  [ "$status" != 0 ]
  [[ "$output" == *zram* ]]
  [ ! -e "$WORK/unexpected-apt" ]
}

@test "real temporary DEB maintainer activation is audited before and after APT" {
  mkdir -p "$WORK/repository" "$WORK/pkg/DEBIAN" "$WORK/pkg/usr/lib/systemd/system" "$WORK/lists/partial" "$WORK/cache/archives/partial"
  cat >"$WORK/pkg/DEBIAN/control" <<'CONTROL'
Package: vaio-task6-fixture
Version: 1.0
Architecture: all
Maintainer: Disposable VM test <nobody@example.invalid>
Description: Disposable package transaction fixture
CONTROL
  cat >"$WORK/pkg/DEBIAN/postinst" <<'SH'
#!/bin/sh
set -e
systemctl daemon-reload
systemctl enable --now vaio-task6-fixture.service
SH
  chmod 755 "$WORK/pkg/DEBIAN/postinst"
  cat >"$WORK/pkg/usr/lib/systemd/system/vaio-task6-fixture.service" <<'UNIT'
[Unit]
Description=Disposable package service
[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
UNIT
  dpkg-deb --build "$WORK/pkg" "$WORK/repository/vaio-task6-fixture_1.0_all.deb" >/dev/null
  python3 - <<'PY'
import hashlib, os, pathlib
p = pathlib.Path(os.environ["WORK"])
deb = p / "repository/vaio-task6-fixture_1.0_all.deb"
control = (p / "pkg/DEBIAN/control").read_text()
(p / "repository/Packages").write_text(control + f"Filename: ./{deb.name}\nSize: {deb.stat().st_size}\nSHA256: {hashlib.sha256(deb.read_bytes()).hexdigest()}\n\n")
PY
  printf 'deb [trusted=yes] file:%s ./\n' "$WORK/repository" >"$WORK/sources.list"
  export APT_CONFIG="$WORK/apt.conf"
  cat >"$APT_CONFIG" <<CONF
Dir::Etc::sourcelist "$WORK/sources.list";
Dir::Etc::sourceparts "-";
Dir::State::lists "$WORK/lists";
Dir::Cache "$WORK/cache";
APT::Sandbox::User "root";
CONF
  sudo env "APT_CONFIG=$APT_CONFIG" apt-get update >/dev/null
  touch "$WORK/fixture-created"
  run bash -c '
        set -euo pipefail
        source "$ROOT/lib/packages.sh"
        source "$ROOT/lib/backup.sh"
        apt_plan baseline vaio-task6-fixture
        run_id=$(begin_run)
        sudo() {
            before="$XDG_STATE_HOME/vaio-fe16-dev-setup/runs/$run_id/packages-baseline-before.json"
            [[ -s $before ]] || return 98
            command sudo "$@"
        }
        apt_apply "$run_id" baseline --confirmed "$APT_PLAN_TOKEN" vaio-task6-fixture
        python3 - "$XDG_STATE_HOME/vaio-fe16-dev-setup/runs/$run_id" <<"PY"
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
before = json.loads((p / "packages-baseline-before.json").read_text())
after = json.loads((p / "packages-baseline-after.json").read_text())
assert "vaio-task6-fixture\tinstall ok installed" not in before["inventory"]
assert "vaio-task6-fixture\tinstall ok installed\t1.0" in after["inventory"]
service = after["inventory"].split("system:vaio-task6-fixture.service\n", 1)[1].split("ManagerEvidence=", 1)[0]
assert "ActiveState=active" in service
assert "UnitFileState=enabled" in service
assert after["apt_exit"] == 0
print("temporary DEB 1.0: before audit existed at install; postinst enabled and activated service; after audit retained version and state")
PY
        apt_plan baseline vaio-task6-fixture
    '
  printf '%s\n' "$output"
  [ "$status" = 0 ]
  [[ "$output" == *'temporary DEB 1.0:'* && "$output" == *missing=none* ]]
  run systemctl is-active vaio-task6-fixture.service
  [ "$status" = 0 ]
}

@test "a real manager introduced after preview blocks apply before APT" {
  cat >"$WORK/personal.service" <<'UNIT'
[Unit]
Description=Private manager
[Service]
ExecStart=/usr/sbin/zramctl /dev/zram0
UNIT
  touch "$WORK/manager-created"
  run bash -c '
        set -euo pipefail
        source "$ROOT/lib/packages.sh"
        source "$ROOT/lib/backup.sh"
        apt-get() {
            [[ " $* " == *" --simulate "* ]] || { touch "$WORK/unexpected-apt"; return 99; }
            printf "Inst vaio-task6-fixture (1.0 fixture [all])\n"
        }
        sudo() {
            if [[ ${1:-} == env && " $* " == *" apt-get "* ]]; then
                touch "$WORK/unexpected-apt"
                return 99
            fi
            command sudo "$@"
        }
        apt_plan baseline vaio-task6-fixture
        run_id=$(begin_run)
        sudo install -m 644 "$WORK/personal.service" /run/systemd/system/vaio-task6-personal.service
        sudo systemctl daemon-reload
        apt_apply "$run_id" baseline --confirmed "$APT_PLAN_TOKEN" vaio-task6-fixture
    '
  [ "$status" != 0 ]
    [[ "$output" == *'state changed after preview'* ]]
  [ ! -e "$WORK/unexpected-apt" ]
  [ -z "$(find "$XDG_STATE_HOME" -name packages-baseline-before.json)" ]
}
