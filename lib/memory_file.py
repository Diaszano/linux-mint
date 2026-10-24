#!/usr/bin/env python3
"""Narrow privileged writes; the caller retains ownership of the run journal."""
import json
import os
import re
from pathlib import Path
import stat
import subprocess
import sys
import uuid

import manifest as m

TARGETS = {
    'zram': '/etc/default/zramswap',
    'swappiness': '/etc/sysctl.d/90-vaio-fe16-swappiness.conf',
}

def privileged_backup(path, mode, uid, gid, data):
    run_path = m.run_path(os.path.basename(os.path.dirname(os.path.dirname(path))))
    prefix = run_path + '/backups/'
    if not path.startswith(prefix) or not re.fullmatch(r'[0-9a-f]{32}', path[len(prefix):]):
        raise m.UnsafeState('backup path not allowed')
    with m.parent_fd(path) as (parent, name):
        if stat.S_IMODE(os.fstat(parent).st_mode) != 0o700:
            raise m.UnsafeState('unsafe backup directory')
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        try:
            with os.fdopen(os.dup(fd), 'wb') as stream:
                stream.write(data)
                stream.flush()
            os.fchown(fd, uid, gid)
            os.fchmod(fd, mode)
            os.fsync(fd)
            os.fsync(parent)
        finally:
            os.close(fd)


def identity(info):
    return 'missing' if info is None else ':'.join(str(n) for n in m.file_identity(info))


def privileged_replace(target, expected, expected_identity, data, metadata=None):
    if target not in TARGETS.values():
        raise m.UnsafeState('target not allowed')
    with m.parent_fd(target) as (parent, name):
        current, info = m.read_file(parent, name)
        if (m.digest(current) or 'missing') != expected or identity(info) != expected_identity:
            raise m.UnsafeState('target changed; checksum or inode conflict')
        if metadata is None:
            metadata = (stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid) if info else (0o644, 0, 0)
        if metadata[1:] != (0, 0):
            raise m.UnsafeState('memory target must be root owned')
        temp = '.vaio-memory-' + uuid.uuid4().hex
        saved = None
        try:
            if data is not None:
                saved = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                0o600, dir_fd=parent)
                with os.fdopen(os.dup(saved), 'wb') as stream:
                    stream.write(data)
                    stream.flush()
                os.fchown(saved, metadata[1], metadata[2])
                os.fchmod(saved, metadata[0])
                os.fsync(saved)
            checked, checked_info = m.read_file(parent, name)
            if checked != current or identity(checked_info) != identity(info):
                raise m.UnsafeState('target substituted during write')
            if data is None:
                os.unlink(name, dir_fd=parent)
            else:
                os.replace(temp, name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        finally:
            if saved is not None:
                os.close(saved)
                try:
                    os.unlink(temp, dir_fd=parent)
                except FileNotFoundError:
                    pass


def write_target(target, current, info, data, metadata=None):
    command = ['sudo', '--', sys.executable, str(Path(__file__).resolve()),
               'remove' if data is None else 'replace', target,
               m.digest(current) or 'missing', identity(info)]
    if metadata is not None:
        command.extend(str(value) for value in metadata)
    subprocess.run(command, input=data or b'', check=True)


def install(run, module, data):
    target = TARGETS[module]
    with m.journal(run) as (fd, events), m.parent_fd(target) as (parent, name):
        before, info = m.read_file(parent, name)
        if before == data:
            return
        snapshots = [e for e in events if e['event'] == 'snapshot' and e.get('path') == target]
        if snapshots and snapshots[0]['module'] != module:
            raise m.UnsafeState('target owned by another module')
        if not snapshots:
            backup = None
            if before is not None:
                backup = m.run_path(run) + '/backups/' + uuid.uuid4().hex
                state = os.environ.get('XDG_STATE_HOME') or str(Path.home() / '.local/state')
                subprocess.run(['sudo', 'env', 'XDG_STATE_HOME=' + state,
                                sys.executable, str(Path(__file__).resolve()),
                                'backup', backup, str(stat.S_IMODE(info.st_mode)),
                                str(info.st_uid), str(info.st_gid)],
                               input=before, check=True)
            m.append_event(fd, dict(event='snapshot', module=module, path=target, backup=backup,
                                   before_sha256=m.digest(before), mode=stat.S_IMODE(info.st_mode) if info else None,
                                   uid=info.st_uid if info else None, gid=info.st_gid if info else None))
        m.append_event(fd, dict(event='intent', module=module, path=target,
                               before_sha256=m.digest(before), intended_sha256=m.digest(data)))
        write_target(target, before, info, data)
        m.append_event(fd, dict(event='applied', module=module, path=target, applied_sha256=m.digest(data)))


def audit(run, module, phase, values):
    if module not in TARGETS or phase not in ('before', 'masked', 'activating', 'active', 'sysctl-before', 'sysctl-applied'):
        raise m.UnsafeState('invalid memory audit')
    path = m.run_path(run) + '/memory-' + module + '-' + phase + '.json'
    with m.journal(run), m.parent_fd(path) as (parent, name):
        fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        with os.fdopen(fd, 'w') as stream:
            json.dump(values, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.fsync(parent)


def read_audit(run, module, phase):
    with m.journal(run), m.parent_fd(m.run_path(run) + '/memory-' + module + '-' + phase + '.json') as (parent, name):
        data, info = m.read_file(parent, name)
        if info is None:
            return None
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
            raise m.UnsafeState('unsafe memory audit')
        return json.loads(data)


def rollback_files(run, apply):
    success = True
    active = read_audit(run, 'zram', 'active')
    activating = read_audit(run, 'zram', 'activating')
    if active or activating:
        print('Manual recovery required: zram is active; preserving active swap and service state.')
        return False
    with m.journal(run, writable=apply) as (fd, events):
        operations, _ = m.rollback_operations(events)
        progress = m.rollback_history(events)
        for index, kind, record in operations:
            if kind != 'file' or record['snapshot']['path'] not in TARGETS.values() or progress.get(index) == 'applied':
                continue
            snapshot = record['snapshot']
            if record['intent']:
                print('Manual recovery required: interrupted memory file intent: ' + snapshot['path'])
                success = False
                continue
            target = snapshot['path']
            with m.parent_fd(target) as (parent, name):
                current, info = m.read_file(parent, name)
            if progress.get(index) == 'intent' and m.digest(current) == snapshot['before_sha256']:
                if apply:
                    m.append_event(fd, dict(event='rollback', operation=index, status='applied'))
                continue
            if m.digest(current) != record['applied']['applied_sha256']:
                print('Manual recovery required: memory file changed: ' + target)
                success = False
                continue
            original = None
            if snapshot['backup']:
                with m.parent_fd(snapshot['backup']) as (bp, bn):
                    original, saved = m.read_file(bp, bn)
                    if (m.digest(original) != snapshot['before_sha256'] or saved is None
                            or (stat.S_IMODE(saved.st_mode), saved.st_uid, saved.st_gid)
                            != (snapshot['mode'], snapshot['uid'], snapshot['gid'])):
                        raise m.UnsafeState('memory backup changed')
            print('Restore memory file: ' + target)
            if apply:
                if progress.get(index) is None:
                    m.append_event(fd, dict(event='rollback', operation=index, status='intent'))
                metadata = (snapshot['mode'], snapshot['uid'], snapshot['gid']) if original is not None else None
                write_target(target, current, info, original, metadata)
                m.append_event(fd, dict(event='rollback', operation=index, status='applied'))
    return success


def main():
    action, *args = sys.argv[1:]
    if action in ('replace', 'remove'):
        if len(args) not in (3, 6):
            raise m.UnsafeState('invalid replacement arguments')
        metadata = tuple(int(v) for v in args[3:]) if len(args) == 6 else None
        privileged_replace(*args[:3], sys.stdin.buffer.read() if action == 'replace' else None, metadata)
    elif action == 'backup':
        if len(args) != 4:
            raise m.UnsafeState('invalid backup arguments')
        privileged_backup(args[0], int(args[1]), int(args[2]), int(args[3]), sys.stdin.buffer.read())
    elif action == 'install':
        install(*args, sys.stdin.buffer.read())
    elif action == 'audit':
        audit(*args[:3], json.loads(args[3]))
    elif action == 'read':
        print(json.dumps(read_audit(*args)))
    elif action == 'rollback':
        if not rollback_files(args[0], args[1] == 'apply'):
            return 1
    else:
        raise m.UnsafeState('unknown memory operation')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print('Memory operation refused: ' + str(exc), file=sys.stderr)
        sys.exit(1)
