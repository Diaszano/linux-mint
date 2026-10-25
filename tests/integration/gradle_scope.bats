#!/usr/bin/env bats
setup() {
  [[ $(hostname) == vaio-fe16-test-vm && $(cat /proc/1/comm) == systemd ]] || skip 'Run only in the disposable Noble QEMU VM'
  command -v gradle >/dev/null || skip 'Install Gradle in the disposable VM'
  ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export ROOT WORK="$BATS_TEST_TMPDIR" GRADLE_USER_HOME="$BATS_TEST_TMPDIR/gradle-home"
  export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
  export PATH="$JAVA_HOME/bin:$PATH"
  mkdir -p "$WORK/project/src/main/java/demo" "$GRADLE_USER_HOME"
  chmod 700 "$WORK" "$GRADLE_USER_HOME" "$(dirname "$WORK")"
  cat >"$WORK/project/gradlew" <<'SH'
#!/usr/bin/env bash
exec gradle "$@"
SH
  chmod +x "$WORK/project/gradlew"
  cat >"$WORK/project/build.gradle" <<'GRADLE'
plugins { id 'java' }
tasks.named('compileJava') {
  options.fork = true
  doFirst {
    long pid = ProcessHandle.current().pid()
    def child = new ProcessBuilder('sleep', '8').start()
    new File(project.findProperty('pidFile')).text = "${pid}\n${child.pid()}\n"
    Thread.sleep(3000)
    child.destroy()
    child.waitFor()
  }
}
tasks.register('recordScope') {
  doLast {
    new File(project.findProperty('pidFile')).text = "${ProcessHandle.current().pid()}\n"
    Thread.sleep(1000)
  }
}
GRADLE
  for ((i = 0; i < 64; i++)); do
    printf 'package demo; public class C%s { public int value() { return %s; } }\n' "$i" "$i" >"$WORK/project/src/main/java/demo/C$i.java"
  done
}

teardown() {
  [[ -n ${GRADLE_USER_HOME:-} ]] || return 0
  gradle --stop >/dev/null 2>&1 || true
}

@test "no-daemon single-use Gradle daemon and child stay in the verified build cgroup" {
  run python3 - <<'PY'
import os, pathlib, subprocess, time
root, work = pathlib.Path(os.environ['ROOT']), pathlib.Path(os.environ['WORK'])
pid_file = work / 'pids'
cmd = [str(root / 'bin/dev-build'), str(work / 'project/gradlew'), 'compileJava', '--no-daemon',
       '--console=plain', '-Dorg.gradle.jvmargs=-Xmx256m', f'-PpidFile={pid_file}',
       ]
p = subprocess.Popen(cmd, cwd=work / 'project', stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    deadline = time.monotonic() + 40
    while not pid_file.exists():
        if p.poll() is not None:
            raise AssertionError('Gradle exited before writing process IDs:\n' + p.stdout.read())
        if time.monotonic() > deadline:
            p.terminate()
            raise AssertionError('timed out waiting for Gradle task')
        time.sleep(.05)
    daemon, child = map(int, pid_file.read_text().splitlines())
    def cgroup(pid):
        return next(line.split('::', 1)[1] for line in pathlib.Path(f'/proc/{pid}/cgroup').read_text().splitlines() if '::' in line)
    cg = cgroup(daemon)
    assert 'dev-build-' in cg and cg.endswith('.scope'), cg
    assert cgroup(child) == cg, (cg, cgroup(child))
    args = pathlib.Path(f'/proc/{daemon}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
    assert 'GradleDaemon' in args, args
    control_dir = pathlib.Path('/sys/fs/cgroup') / cg.lstrip('/')
    for name in ('cpu.max', 'memory.high', 'memory.max', 'memory.swap.max', 'pids.max'):
        assert (control_dir / name).is_file(), name
    assert int((control_dir / 'memory.high').read_text()) < int((control_dir / 'memory.max').read_text())
    compile_deadline = time.monotonic() + 10
    compiler = None
    while time.monotonic() < compile_deadline and compiler is None:
        for entry in (control_dir / 'cgroup.procs').read_text().splitlines():
            try:
                process_args = pathlib.Path(f'/proc/{entry}/cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
            except FileNotFoundError:
                continue
            if 'javac' in process_args or 'Gradle Worker Daemon' in process_args:
                compiler = int(entry)
                break
        if compiler is None:
            if p.poll() is not None:
                raise AssertionError('Gradle compilation exited before compiler/worker observation:\n' + p.stdout.read())
            time.sleep(.01)
    assert compiler is not None, 'no forked Java compiler or Gradle worker observed in build scope'
    assert cgroup(compiler) == cg, (cg, cgroup(compiler))
    output, _ = p.communicate(timeout=45)
    assert p.returncode == 0, output
    assert 'dev-run: verified' in output, output
    print('single-use Gradle daemon, compiler/worker', compiler, 'and child contained in', cg)
finally:
    if p.poll() is None:
        p.terminate()
    try:
        p.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate(timeout=5)
PY
  [ "$status" = 0 ]
  [[ "$output" == *'single-use Gradle daemon, compiler/worker'* ]]
  printf '%s\n' "$output"
}

@test "preexisting reusable daemon is outside the dev-build scope guarantee" {
  gradle --daemon -p "$WORK/project" help --console=plain >/dev/null
  run python3 - <<'PY'
import os, pathlib, subprocess, time
root, work = pathlib.Path(os.environ['ROOT']), pathlib.Path(os.environ['WORK'])
pid_file = work / 'reused-pid'
cmd = [str(root / 'bin/dev-build'), str(work / 'project/gradlew'), 'recordScope',
       '--console=plain', f'-PpidFile={pid_file}']
p = subprocess.Popen(cmd, cwd=work / 'project', stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
try:
    deadline = time.monotonic() + 30
    while not pid_file.exists():
        if p.poll() is not None:
            raise AssertionError('Gradle exited before recording its daemon:\n' + p.stdout.read())
        if time.monotonic() > deadline:
            p.terminate()
            raise AssertionError('timed out waiting for reused daemon')
        time.sleep(.05)
    pid = int(pid_file.read_text())
    cg = next(line.split('::', 1)[1] for line in pathlib.Path(f'/proc/{pid}/cgroup').read_text().splitlines() if '::' in line)
    assert 'dev-build-' not in cg, cg
    output, _ = p.communicate(timeout=35)
    assert p.returncode == 0, output
    print('preexisting Gradle daemon reused outside dev-build scope:', cg)
finally:
    if p.poll() is None:
        p.terminate()
    try:
        p.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate(timeout=5)
PY
  [ "$status" = 0 ]
  [[ "$output" == *'preexisting Gradle daemon reused outside dev-build scope'* ]]
  printf '%s\n' "$output"
}

@test "observer assertion failure terminates and waits for its scoped workload" {
  run python3 - <<'PY'
import os, pathlib, subprocess, sys, time
root, work = pathlib.Path(os.environ['ROOT']), pathlib.Path(os.environ['WORK'])
pid_file = work / 'failure-pid'
code = "import os,pathlib,time; pathlib.Path(os.environ['PID_FILE']).write_text(str(os.getpid())); time.sleep(30)"
env = dict(os.environ, PID_FILE=str(pid_file))
p = subprocess.Popen([str(root / 'bin/dev-build'), sys.executable, '-c', code],
                     cwd=work / 'project', env=env, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True)
try:
    deadline = time.monotonic() + 10
    while not pid_file.exists():
        if p.poll() is not None:
            raise AssertionError('workload exited before publishing its PID:\n' + p.stdout.read())
        if time.monotonic() > deadline:
            raise AssertionError('timed out waiting for scoped workload')
        time.sleep(.05)
    child = int(pid_file.read_text())
    raise AssertionError('injected cgroup-membership assertion failure')
except AssertionError as exc:
    if str(exc) != 'injected cgroup-membership assertion failure':
        raise
finally:
    if p.poll() is None:
        p.terminate()
    try:
        p.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        p.kill()
        p.communicate(timeout=5)
assert p.poll() is not None
deadline = time.monotonic() + 5
while pathlib.Path(f'/proc/{child}').exists() and time.monotonic() < deadline:
    time.sleep(.05)
assert not pathlib.Path(f'/proc/{child}').exists(), f'scoped child {child} survived wrapper cleanup'
print('injected observer failure reaped wrapper and scoped child')
PY
  [ "$status" = 0 ]
  [[ "$output" == *'injected observer failure reaped wrapper and scoped child'* ]]
}
