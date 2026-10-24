#!/usr/bin/env bats
setup() {
    [[ $(hostname) == vaio-fe16-test-vm && $(cat /proc/1/comm) == systemd ]] || skip 'Run only in the disposable Noble QEMU VM'
    ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
    export ROOT WORK="$BATS_TEST_TMPDIR"
}

teardown() {
    if [[ -n ${TEST_SLICE:-} ]]; then
        systemctl --user stop "$TEST_SLICE"
        systemctl --user revert "$TEST_SLICE" >/dev/null 2>&1 || true
    fi
    if [[ -n ${swapfile:-} && -f $swapfile ]]; then
        sudo swapoff "$swapfile" 2>/dev/null || true
    fi
}

limited_slice() {
    export TEST_SLICE="devtest${BATS_TEST_NUMBER}p$$.slice"
    systemctl --user start "$TEST_SLICE"
    systemctl --user set-property --runtime "$TEST_SLICE" "MemoryHigh=$1" "MemoryMax=$2" "MemorySwapMax=$3" "TasksMax=$4"
    mkdir -p "$WORK/bin"
    cat >"$WORK/bin/systemd-run" <<'SH'
#!/usr/bin/env bash
exec /usr/bin/systemd-run --slice="$TEST_SLICE" "$@"
SH
    chmod +x "$WORK/bin/systemd-run"
    export PATH="$WORK/bin:$PATH"
}

@test "real kernel limits cover the payload and its ordinary child" {
    run "$ROOT/bin/dev-run" build python3 -c '
import os, pathlib, subprocess
cg = pathlib.Path("/proc/self/cgroup").read_text().strip()
child = subprocess.check_output(["cat", "/proc/self/cgroup"], text=True).strip()
assert cg == child and "dev-build-" in cg and cg.endswith(".scope")
p = pathlib.Path("/sys/fs/cgroup") / cg.split("::", 1)[1].lstrip("/")
q, period = map(int, (p / "cpu.max").read_text().split())
threads = int(subprocess.check_output(["nproc"], text=True))
assert q * 100 <= min(800, max(1, threads - 2) * 100) * period
for name in ("memory.high", "memory.max", "memory.swap.max", "pids.max"):
    assert (p / name).read_text().strip().isdigit(), name
assert int((p / "memory.high").read_text()) < int((p / "memory.max").read_text())
print("live payload and child membership:", cg)
print("live controls:", {n: (p / n).read_text().strip() for n in ("cpu.max", "memory.high", "memory.max", "memory.swap.max", "pids.max")})
'
    [ "$status" = 0 ]
    [[ "$output" == *'live payload and child membership:'* ]]
    printf '%s\n' "$output"
}

@test "real launcher preserves argv exit 7 and payload SIGTERM" {
    run "$ROOT/bin/dev-run" heavy python3 -c 'import sys; assert sys.argv[1:] == ["a b", "", "*;$(false)"]; sys.exit(7)' 'a b' '' '*;$(false)'
    [ "$status" = 7 ]
    run "$ROOT/bin/dev-run" heavy bash -c 'kill -TERM $$'
    [ "$status" = 143 ]
}

@test "SIGTERM and SIGINT reach the payload and clean the scope and descendants" {
    run python3 - <<'PY'
import os, pathlib, signal, subprocess, time
root, work = os.environ["ROOT"], pathlib.Path(os.environ["WORK"])
for sig in (signal.SIGTERM, signal.SIGINT):
    ready = work / f"ready{sig}"
    caught = work / f"caught{sig}"
    code = '''import os, pathlib, signal, subprocess, sys, time
ready, caught = map(pathlib.Path, sys.argv[1:])
def done(sig, frame):
    caught.write_text(str(sig))
    sys.exit(128 + sig)
signal.signal(signal.SIGTERM, done)
signal.signal(signal.SIGINT, done)
child = subprocess.Popen(["sleep", "60"])
ready.write_text(pathlib.Path("/proc/self/cgroup").read_text() + str(child.pid))
while True: time.sleep(.02)
'''
    p = subprocess.Popen([root + "/bin/dev-run", "heavy", "python3", "-c", code, str(ready), str(caught)])
    deadline = time.monotonic() + 15
    while not ready.exists():
        assert p.poll() is None, "launcher exited before payload started"
        assert time.monotonic() < deadline
        time.sleep(.02)
    cg, child_pid = ready.read_text().splitlines()
    p.send_signal(sig)
    assert p.wait(timeout=10) == 128 + sig
    assert caught.read_text() == str(sig), "signal not forwarded"
    path = pathlib.Path("/sys/fs/cgroup") / cg.split("::", 1)[1].lstrip("/")
    assert not path.exists(), "scope survived interruption"
    try:
        state = pathlib.Path(f"/proc/{child_pid}/stat").read_text().split()[2]
        assert state == "Z", "live descendant survived"
    except FileNotFoundError:
        pass
PY
    [ "$status" = 0 ]
}

@test "stricter ancestor limits are reported and emulator respects inherited RAM cap" {
    limited_slice 512M 1G 0 128
    run "$ROOT/bin/dev-run" build true
    [ "$status" = 0 ]
    [[ "$output" == *'memory.high=536870912 memory.max=1073741824 memory.swap.max=0 pids.max=128'* ]]
    export XDG_CONFIG_HOME="$WORK/config"
    mkdir -p "$XDG_CONFIG_HOME/vaio-dev"
    printf 'emulator\t200\t9\t10\t0\t128\n' >"$XDG_CONFIG_HOME/vaio-dev/profiles.conf"
    chmod 600 "$XDG_CONFIG_HOME/vaio-dev/profiles.conf"
    run "$ROOT/bin/dev-run" emulator touch "$WORK/sentinel"
    [ "$status" != 0 ]
    [[ "$output" == *'Effective emulator cap cannot sustain the 3-GiB guest'* ]]
    [ ! -f "$WORK/sentinel" ]
}

@test "private IPC is mode 0700 during launch and removed afterwards" {
    run "$ROOT/bin/dev-run" heavy bash -c '
        found=0
        for path in "$XDG_RUNTIME_DIR"/dev-run.*; do
            [[ -d $path ]] || continue
            [[ $(stat -c %a "$path") == 700 ]] || exit 8
            found=1
        done
        ((found))
    '
    [ "$status" = 0 ]
    [ -z "$(find "$XDG_RUNTIME_DIR" -maxdepth 1 -name 'dev-run.*' -print -quit)" ]
}

@test "memory and swap exhaustion OOM kills only the bounded descendant" {
    # The disposable VM gets a temporary swap device; all allocation stays under 64 MiB + 16 MiB.
    swapfile="$WORK/swap"
    sudo fallocate -l 128M "$swapfile"
    sudo chmod 600 "$swapfile"
    sudo mkswap "$swapfile" >/dev/null
    sudo swapon "$swapfile"
    cat >"$WORK/pressure.py" <<'PYTHON'
import pathlib, time
cg = pathlib.Path("/proc/self/cgroup").read_text().strip()
assert "dev-build-" in cg
print("allocator membership", cg, flush=True)
a = []
for i in range(256):
    a.append(bytearray(1024 * 1024))
    time.sleep(.005)
PYTHON
    limited_slice 63M 64M 16M 128
    run python3 - <<'PYTHON'
import os, pathlib, subprocess, time
cg = subprocess.check_output(["systemctl", "--user", "show", os.environ["TEST_SLICE"], "-p", "ControlGroup", "--value"], text=True).strip()
p = pathlib.Path("/sys/fs/cgroup") / cg.lstrip("/")
child = subprocess.Popen([os.environ["ROOT"] + "/bin/dev-run", "build", "python3", os.environ["WORK"] + "/pressure.py"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
peak = 0
deadline = time.monotonic() + 45
while child.poll() is None:
    peak = max(peak, int((p / "memory.swap.current").read_text()))
    if time.monotonic() > deadline:
        child.terminate()
        child.wait(timeout=10)
        raise AssertionError("bounded allocator did not exhaust its cap")
    time.sleep(.005)
print(child.communicate()[0], end="")
events = dict(line.split() for line in (p / "memory.events").read_text().splitlines())
print("bounded pressure", cg, "child_exit", child.returncode, "swap_peak", peak, "events", events, flush=True)
assert child.returncode == 137
assert int(events["oom_kill"]) >= 1
assert 0 < peak <= 16 * 1024 * 1024
PYTHON
    result=$status
    printf '%s\n' "$output"
    sudo swapoff "$swapfile"
    [ "$result" = 0 ]
    [[ "$output" == *'bounded pressure'* ]]
    [ -r /proc/self/status ]
}
