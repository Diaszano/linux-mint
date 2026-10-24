#!/usr/bin/env bats
# shellcheck disable=SC2016

setup() {
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export ROOT HOME="$BATS_TEST_TMPDIR/home" XDG_STATE_HOME="$BATS_TEST_TMPDIR/state"
  export PACKAGE_LOG="$BATS_TEST_TMPDIR/apt.log" FIXTURE="$BATS_TEST_TMPDIR"
  mkdir -p "$HOME" "$FIXTURE/bin"
  export PATH="$FIXTURE/bin:$PATH"
  printf 'bash\tinstall ok installed\t5.2\n' >"$FIXTURE/packages"
  : >"$FIXTURE/units"
  : >"$FIXTURE/swaps"
  : >"$FIXTURE/metadata"
  cat >"$FIXTURE/bin/probe" <<'SH'
#!/usr/bin/env bash
case "${0##*/}" in
    dpkg-query) [[ ! -e $FIXTURE/unknown ]] || exit 2; cat "$FIXTURE/packages" ;;
    swapon) cat "$FIXTURE/swaps" ;;
    zramctl) if [[ -f $FIXTURE/zram ]]; then cat "$FIXTURE/zram"; fi ;;
    systemctl)
        case "${1:-}" in --system|--user) shift ;; esac
        case "$1" in
            list-units|list-unit-files) cat "$FIXTURE/units" ;;
            show) [[ ! -e $FIXTURE/show-failed ]] || exit 1; cat "$FIXTURE/metadata" ;;
            cat) cat "$FIXTURE/template" ;;
            *) exit 99 ;;
        esac ;;
    apt-get)
        printf '%s\n' "$*" >>"$PACKAGE_LOG"
        printf '%s\n' "${APT_CONFIG-<unset>}" >>"$FIXTURE/apt-config.log"
        [[ ! -e $FIXTURE/offline ]] || exit 100
        if [[ " $* " == *' --simulate '* ]]; then
            if [[ -f $FIXTURE/simulation ]]; then cat "$FIXTURE/simulation"; else printf 'Inst hello (2.10 Ubuntu:24.04/noble [amd64])\n'; fi
        else
            [[ -f $FIXTURE/before-observed ]] || exit 98
            printf 'hello\tinstall ok installed\t2.10\n' >>"$FIXTURE/packages"
            [[ ! -e $FIXTURE/install-failed ]] || exit 100
            if [[ -e $FIXTURE/fail-after-install-query ]]; then touch "$FIXTURE/unknown"; fi
        fi ;;
    sudo) printf '%s\n' "$@" >"$FIXTURE/sudo-args"; exec env -u APT_CONFIG "$@" ;;
esac
SH
  chmod +x "$FIXTURE/bin/probe"
  for name in dpkg-query swapon zramctl systemctl apt-get sudo; do ln -s probe "$FIXTURE/bin/$name"; done
}

library() { bash -c 'set -euo pipefail; source "$ROOT/lib/packages.sh"; eval "$1"' _ "$1"; }

@test "baseline selection excludes memory managers and Docker" {
  run library 'package_selection baseline'
  [ "$status" = 0 ]
  [[ "$output" == *git-lfs* && "$output" == *ninja-build* ]]
  [[ "$output" != *zram* && "$output" != *earlyoom* && "$output" != *docker* ]]
}

@test "simulation lists missing packages without update or mutation" {
  run library 'apt_plan baseline hello'
  [ "$status" = 0 ]
  [[ "$output" == *missing=hello* && "$output" == *plan_token=* ]]
  [[ "$(cat "$PACKAGE_LOG")" == *'--simulate'* ]]
  [[ "$(cat "$PACKAGE_LOG")" != *update* ]]
  [ ! -d "$XDG_STATE_HOME" ]
}

@test "installed packages are no-op without APT" {
  run library 'apt_plan baseline bash'
  [ "$status" = 0 ]
  [[ "$output" == *missing=none* ]]
  [ ! -e "$PACKAGE_LOG" ]
}

@test "existing zram package swap or inactive custom manager blocks before APT" {
  for scenario in package swap unit; do
    case "$scenario" in
      package) printf 'systemd-zram-generator\tinstall ok installed\t1.0\n' >>"$FIXTURE/packages" ;;
      swap) printf '/dev/zram0 partition 4G 100\n' >"$FIXTURE/swaps" ;;
      unit)
        printf 'personal.service enabled enabled\n' >"$FIXTURE/units"
        printf 'Id=personal.service\nDescription=Private helper\nExecStart={ path=/usr/sbin/zramctl ; argv[]=/usr/sbin/zramctl /dev/zram0 ; }\nActiveState=inactive\n' >"$FIXTURE/metadata"
        ;;
    esac
    run library 'apt_plan zram zram-tools'
    [ "$status" != 0 ]
    [ ! -e "$PACKAGE_LOG" ]
    printf 'bash\tinstall ok installed\t5.2\n' >"$FIXTURE/packages"
    : >"$FIXTURE/swaps"
  done
}

@test "OOM manager under unrelated unit name and unknown inventory block before APT" {
  printf 'watchdog.service enabled enabled\n' >"$FIXTURE/units"
  printf 'Id=watchdog.service\nDescription=Local pressure manager\nExecStart={ path=/usr/bin/nohang ; }\nActiveState=active\n' >"$FIXTURE/metadata"
  run library 'apt_plan earlyoom earlyoom'
  [ "$status" != 0 ]
  [ ! -e "$PACKAGE_LOG" ]
  touch "$FIXTURE/show-failed"
  run library 'apt_plan baseline hello'
  [ "$status" != 0 ]
  [ ! -e "$PACKAGE_LOG" ]
}

@test "unreadable package inventory blocks all modules" {
  touch "$FIXTURE/unknown"
  run library 'apt_plan baseline hello'
  [ "$status" != 0 ]
  [ ! -e "$PACKAGE_LOG" ]
}

@test "Docker CE provider is reused and distro packages cannot replace it" {
  printf 'docker-ce\tinstall ok installed\t27.0\n' >>"$FIXTURE/packages"
  run library 'package_selection docker'
  [ "$status" = 0 ]
  [[ "$output" == *docker-ce* && "$output" != *docker.io* ]]
  run library 'apt_plan docker docker.io'
  [ "$status" != 0 ]
  [ ! -e "$PACKAGE_LOG" ]
}

@test "simulation failure and offline APT fail cleanly" {
  touch "$FIXTURE/offline"
  run library 'apt_plan baseline hello'
  [ "$status" != 0 ]
  [[ "$output" == *simula* ]]
}

@test "removals upgrades and unselected transitive managers are rejected" {
  for transaction in 'Remv bash [5.2]' 'Inst bash [5.2] (5.3 Ubuntu)' 'Inst earlyoom (1.8 Ubuntu)'; do
    printf '%s\n' "$transaction" >"$FIXTURE/simulation"
    run library 'apt_plan baseline hello'
    [ "$status" != 0 ]
  done
}

@test "apply requires exact preview token and rechecks conflicts" {
  run library 'apt_apply bad baseline --confirmed bad hello'
  [ "$status" != 0 ]
  [ ! -e "$PACKAGE_LOG" ]
  run library 'apt_plan zram zram-tools; printf "/dev/zram0 partition 4G 100\n" >"$FIXTURE/swaps"; apt_apply bad zram --confirmed "$APT_PLAN_TOKEN" zram-tools'
  [ "$status" != 0 ]
  [ "$(wc -l <"$PACKAGE_LOG")" = 1 ]
}

@test "apply journals before APT and audits actual state even on failure" {
  touch "$FIXTURE/install-failed"
  run library '
        source "$ROOT/lib/backup.sh"
        apt_plan baseline hello
        run_id=$(begin_run)
        sudo() {
            find "$XDG_STATE_HOME" -name "packages-baseline-before.json" | read -r audit || return 98
            touch "$FIXTURE/before-observed"
            command sudo "$@"
        }
        apt_apply "$run_id" baseline --confirmed "$APT_PLAN_TOKEN" hello
    '
  [ "$status" != 0 ]
  [ -f "$FIXTURE/before-observed" ]
  run find "$XDG_STATE_HOME" -name packages-baseline-after.json
  [ "$status" = 0 ]
  [[ "$output" == *packages-baseline-after.json ]]
  run python3 -c 'import glob,json,os; p=glob.glob(os.environ["XDG_STATE_HOME"]+"/**/packages-baseline-after.json",recursive=True)[0]; a=json.load(open(p)); assert a["apt_exit"]==100 and "hello\tinstall ok installed\t2.10" in a["inventory"]'
  [ "$status" = 0 ]
}

@test "configured zram without active swap and incompatible disk priority are blocked" {
  printf '/dev/zram0 4G\n' >"$FIXTURE/zram"
  run library 'apt_plan zram zram-tools'
  [ "$status" != 0 ]
  [ ! -e "$PACKAGE_LOG" ]
  rm "$FIXTURE/zram"
  printf '/swapfile file 4G 150\n' >"$FIXTURE/swaps"
  run library 'apt_plan zram zram-tools'
  [ "$status" != 0 ]
  [ ! -e "$PACKAGE_LOG" ]
}

@test "service inventory retains states without recording arbitrary command secrets" {
  printf 'personal.service enabled enabled\n' >"$FIXTURE/units"
  printf 'Id=personal.service\nActiveState=inactive\nUnitFileState=enabled\nExecStart={ path=/usr/bin/nohang ; argv[]=/usr/bin/nohang --password=secret-sentinel ; }\n' >"$FIXTURE/metadata"
  run library 'preflight_install_inventory; printf "%s" "$PREFLIGHT_SERVICES"'
  [ "$status" = 0 ]
  [[ "$output" == *oom-manager* && "$output" == *ActiveState=inactive* ]]
  [[ "$output" != *secret-sentinel* ]]
}

@test "transitive Docker provider replacement and unknown swap state stop simulation" {
  printf 'docker-ce\tinstall ok installed\t27.0\n' >>"$FIXTURE/packages"
  printf 'Inst docker.io (24.0 Ubuntu)\n' >"$FIXTURE/simulation"
  run library 'apt_plan baseline hello'
  [ "$status" != 0 ]
  [[ "$output" == *provedores* ]]
  rm "$PACKAGE_LOG"
  printf 'garbled swap output\n' >"$FIXTURE/swaps"
  run library 'apt_plan baseline hello'
  [ "$status" != 0 ]
  [ ! -e "$PACKAGE_LOG" ]
}

@test "changed APT resolution after confirmation cannot reach installation" {
  run library '
        source "$ROOT/lib/backup.sh"
        apt_plan baseline hello
        run_id=$(begin_run)
        printf "Inst hello (3.0 Ubuntu)\n" >"$FIXTURE/simulation"
        apt_apply "$run_id" baseline --confirmed "$APT_PLAN_TOKEN" hello
    '
  [ "$status" != 0 ]
  [[ "$output" == *'transação APT mudou'* ]]
  [ "$(wc -l <"$PACKAGE_LOG")" = 2 ]
  [ -z "$(find "$XDG_STATE_HOME" -name packages-baseline-before.json)" ]
}

@test "unchanged plans stay stable through unrelated transient service activity" {
  printf 'apt-news.service static static\n' >"$FIXTURE/units"
  printf 'Id=apt-news.service\nActiveState=activating\nUnitFileState=static\n' >"$FIXTURE/metadata"
  run library '
        apt_plan baseline hello
        first_token=$APT_PLAN_TOKEN
        printf "Id=apt-news.service\nActiveState=inactive\nUnitFileState=static\n" >"$FIXTURE/metadata"
        apt_plan baseline hello
        [[ $first_token == "$APT_PLAN_TOKEN" ]]
        apt_plan baseline hello
        [[ $first_token == "$APT_PLAN_TOKEN" ]]
    '
  [ "$status" = 0 ]
}

@test "a relevant manager state change after planning blocks apply before APT" {
  printf 'personal.service enabled enabled\n' >"$FIXTURE/units"
  printf 'Id=personal.service\nActiveState=inactive\nExecStart={ path=/usr/bin/nohang ; }\n' >"$FIXTURE/metadata"
  run library '
        apt_plan baseline hello
        printf "Id=personal.service\nActiveState=active\nExecStart={ path=/usr/bin/nohang ; }\n" >"$FIXTURE/metadata"
        apt_apply unused baseline --confirmed "$APT_PLAN_TOKEN" hello
    '
  [ "$status" != 0 ]
  [[ "$output" == *'estado mudou'* ]]
  [ "$(wc -l <"$PACKAGE_LOG")" = 1 ]
}

@test "fix-round-1 requested swap managers cannot enter baseline" {
  for package in systemd-swap swapspace dphys-swapfile zswap-tools; do
    run library "apt_plan baseline $package"
    [ "$status" != 0 ]
    [ ! -e "$PACKAGE_LOG" ]
  done
}

@test "fix-round-1 transitive swap managers are rejected by the same classifier" {
  for package in systemd-swap swapspace dphys-swapfile zswap-tools; do
    printf 'Inst %s (1.0 Ubuntu)\n' "$package" >"$FIXTURE/simulation"
    run library 'apt_plan baseline hello'
    [ "$status" != 0 ]
    [[ "$output" == *gerenciador* ]]
  done
}

@test "fix-round-1 installed swap managers block zram before APT" {
  for package in systemd-swap swapspace dphys-swapfile zswap-tools; do
    printf '%s\tinstall ok installed\t1.0\n' "$package" >"$FIXTURE/packages"
    run library 'apt_plan zram zram-tools'
    [ "$status" != 0 ]
    [ ! -e "$PACKAGE_LOG" ]
  done
}

@test "fix-round-1 unrelated template swapon metadata blocks before APT" {
  printf 'personal@.service enabled enabled\n' >"$FIXTURE/units"
  printf '[Unit]\nDescription=Private helper\n[Service]\nExecStart=/usr/sbin/swapon --priority 200 /swapfile\n' >"$FIXTURE/template"
  run library 'apt_plan zram zram-tools'
  [ "$status" != 0 ]
  [ ! -e "$PACKAGE_LOG" ]
}

@test "fix-round-1 production sudo explicitly carries the simulation APT_CONFIG" {
  export APT_CONFIG="$FIXTURE/apt config"
  printf 'APT::Sandbox::User "root";\n' >"$APT_CONFIG"
  touch "$FIXTURE/before-observed"
  run library '
        source "$ROOT/lib/backup.sh"
        apt_plan baseline hello
        run_id=$(begin_run)
        apt_apply "$run_id" baseline --confirmed "$APT_PLAN_TOKEN" hello
    '
  [ "$status" = 0 ]
  run python3 - <<'PY'
import os, pathlib
p = pathlib.Path(os.environ["FIXTURE"])
config = os.environ["APT_CONFIG"]
assert (p / "apt-config.log").read_text().splitlines() == [config] * 3
args = (p / "sudo-args").read_text().splitlines()
assert args[:4] == ["env", "APT_CONFIG=" + config, "DEBIAN_FRONTEND=noninteractive", "apt-get"]
PY
  [ "$status" = 0 ]
}

@test "fix-round-1 successful install then failed discovery records unknown without false package events" {
  touch "$FIXTURE/before-observed" "$FIXTURE/fail-after-install-query"
  run library '
        source "$ROOT/lib/backup.sh"
        apt_plan baseline hello
        run_id=$(begin_run)
        apt_apply "$run_id" baseline --confirmed "$APT_PLAN_TOKEN" hello
    '
  [ "$status" != 0 ]
  run python3 - <<'PY'
import json, os, pathlib
p = next(pathlib.Path(os.environ["XDG_STATE_HOME"]).glob("**/packages-baseline-after.json"))
audit = json.loads(p.read_text())
assert audit["apt_exit"] == 0
assert "[packages]\nunknown\n" in audit["inventory"]
events = [json.loads(line) for line in (p.parent / "manifest.jsonl").read_text().splitlines()]
assert not [event for event in events if event["event"] == "package"]
PY
  [ "$status" = 0 ]
}
