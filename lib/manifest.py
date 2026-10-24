#!/usr/bin/env python3
"""Durable metadata-only journal and owned-file operations."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys
import time
import uuid


class UnsafeState(ValueError):
    pass


def valid_path(value):
    if (not isinstance(value, str) or not value.startswith('/') or value == '/'
            or any(ord(c) < 32 or ord(c) == 127 for c in value)
            or any(part in ('', '.', '..') for part in value.split('/')[1:])):
        raise UnsafeState('invalid path')
    return value


@contextmanager
def parent_fd(path, create=False):
    valid_path(path)
    parts = path.split('/')[1:]
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts[:-1]:
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=fd)
                    os.fsync(fd)
                except FileExistsError:
                    pass
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        yield fd, parts[-1]
    finally:
        os.close(fd)


def state_runs():
    state = os.environ.get('XDG_STATE_HOME') or str(Path.home() / '.local/state')
    return valid_path(state) + '/vaio-fe16-dev-setup/runs'


def private_directory(path):
    with parent_fd(path, create=True) as (parent, name):
        try:
            os.mkdir(name, 0o700, dir_fd=parent)
            os.fsync(parent)
        except FileExistsError:
            pass
        fd = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
                raise UnsafeState('unsafe state permissions')
        finally:
            os.close(fd)


def run_path(run):
    if not re.fullmatch(r'[0-9]{20}-[0-9a-f]{16}', run):
        raise UnsafeState('invalid run')
    return state_runs() + '/' + run


SCHEMAS = {
    'run': {'event', 'run_id'},
    'snapshot': {'event', 'module', 'path', 'backup', 'before_sha256', 'mode', 'uid', 'gid'},
    'intent': {'event', 'module', 'path', 'before_sha256', 'intended_sha256'},
    'applied': {'event', 'module', 'path', 'applied_sha256'},
}


def validate(event):
    if not isinstance(event, dict) or event.get('event') not in SCHEMAS:
        raise UnsafeState('invalid event')
    if set(event) != SCHEMAS[event['event']]:
        raise UnsafeState('invalid fields')
    if event['event'] == 'run':
        run_path(event['run_id'])
        return
    if not isinstance(event['module'], str) or not re.fullmatch(r'[a-z][a-z0-9_-]{0,63}', event['module']):
        raise UnsafeState('invalid module')
    valid_path(event['path'])
    for key, value in event.items():
        if key.endswith('sha256'):
            if value is None and key == 'before_sha256':
                continue
            if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value):
                raise UnsafeState('invalid checksum')
    if event['event'] == 'snapshot':
        absent = event['before_sha256'] is None
        for key in ('backup', 'mode', 'uid', 'gid'):
            if absent != (event[key] is None):
                raise UnsafeState('inconsistent snapshot')
        if not absent:
            valid_path(event['backup'])
            for key in ('mode', 'uid', 'gid'):
                if type(event[key]) is not int or event[key] < 0:
                    raise UnsafeState('invalid metadata')
            if event['mode'] > 0o7777:
                raise UnsafeState('invalid mode')


def no_duplicates(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise UnsafeState('duplicate key')
        result[key] = value
    return result


def read_events(fd, run):
    os.lseek(fd, 0, os.SEEK_SET)
    with os.fdopen(os.dup(fd), 'r', encoding='utf-8') as stream:
        data = stream.read()
    if not data.endswith('\n'):
        raise UnsafeState('incomplete journal')
    events = [json.loads(line, object_pairs_hook=no_duplicates) for line in data.splitlines()]
    for index, event in enumerate(events):
        validate(event)
        if (event['event'] == 'run') != (index == 0):
            raise UnsafeState('invalid run header')
    if not events or events[0] != {'event': 'run', 'run_id': run}:
        raise UnsafeState('wrong run')
    for event in events:
        if event['event'] == 'snapshot' and event['backup'] is not None:
            backup = event['backup']
            prefix = run_path(run) + '/backups/'
            if not backup.startswith(prefix) or not re.fullmatch(r'[0-9a-f]{32}', backup[len(prefix):]):
                raise UnsafeState('foreign backup')
            with parent_fd(backup) as (parent, name):
                saved, info = read_file(parent, name)
                if (info is None or digest(saved) != event['before_sha256']
                        or (stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid)
                        != (event['mode'], event['uid'], event['gid'])):
                    raise UnsafeState('backup changed')
    return events


def append_event(fd, event):
    validate(event)
    data = (json.dumps(event, ensure_ascii=True, sort_keys=True) + '\n').encode('utf-8')
    os.lseek(fd, 0, os.SEEK_END)
    while data:
        data = data[os.write(fd, data):]
    os.fsync(fd)


@contextmanager
def journal(run):
    path = run_path(run)
    with parent_fd(path + '/manifest.jsonl') as (parent, name):
        info = os.fstat(parent)
        if info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise UnsafeState('unsafe run directory')
        fd = os.open(name, os.O_RDWR | os.O_NOFOLLOW, dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) != 0o600:
                raise UnsafeState('unsafe journal')
            fcntl.flock(fd, fcntl.LOCK_EX)
            yield fd, read_events(fd, run)
        finally:
            os.close(fd)


def begin_run():
    previous_umask = os.umask(0o077)
    try:
        runs = state_runs()
        private_directory(str(Path(runs).parent))
        private_directory(runs)
        run = f'{time.time_ns():020d}-{uuid.uuid4().hex[:16]}'
        with parent_fd(runs + '/' + run) as (parent, name):
            os.mkdir(name, 0o700, dir_fd=parent)
            os.fsync(parent)
        path = run_path(run)
        private_directory(path + '/backups')
        with parent_fd(path + '/manifest.jsonl') as (parent, name):
            fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            try:
                append_event(fd, {'event': 'run', 'run_id': run})
                os.fsync(parent)
            finally:
                os.close(fd)
        return run
    finally:
        os.umask(previous_umask)


def read_file(parent, name):
    try:
        info = os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        return None, None
    if not stat.S_ISREG(info.st_mode):
        raise UnsafeState('regular files only')
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    try:
        opened = os.fstat(fd)
        if not stat.S_ISREG(opened.st_mode) or (info.st_dev, info.st_ino) != (opened.st_dev, opened.st_ino):
            raise UnsafeState('file changed')
        with os.fdopen(os.dup(fd), 'rb') as stream:
            data = stream.read()
        after = os.fstat(fd)
        if (opened.st_size, opened.st_mtime_ns, opened.st_ctime_ns) != (after.st_size, after.st_mtime_ns, after.st_ctime_ns):
            raise UnsafeState('file changed')
        return data, opened
    finally:
        os.close(fd)


def digest(data):
    return None if data is None else hashlib.sha256(data).hexdigest()


def write_file(fd, data, info):
    with os.fdopen(os.dup(fd), 'wb') as stream:
        stream.write(data)
        stream.flush()
    os.fchown(fd, info.st_uid, info.st_gid)
    os.fchmod(fd, stat.S_IMODE(info.st_mode))
    os.utime(fd, ns=(info.st_atime_ns, info.st_mtime_ns))
    os.fsync(fd)


def snapshot_locked(fd, events, run, module, path, data, info):
    existing = [event for event in events if event['event'] == 'snapshot' and event['path'] == path]
    if existing:
        if existing[0]['module'] != module:
            raise UnsafeState('file owned by another module')
        return
    event = dict(event='snapshot', module=module, path=path, backup=None,
                 before_sha256=digest(data), mode=None, uid=None, gid=None)
    if data is not None:
        backup = run_path(run) + '/backups/' + uuid.uuid4().hex
        with parent_fd(backup) as (parent, name):
            if stat.S_IMODE(os.fstat(parent).st_mode) != 0o700:
                raise UnsafeState('unsafe backup directory')
            saved = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
            try:
                write_file(saved, data, info)
                os.fsync(parent)
            finally:
                os.close(saved)
        event.update(backup=backup, mode=stat.S_IMODE(info.st_mode), uid=info.st_uid, gid=info.st_gid)
    append_event(fd, event)
    events.append(event)


def owned_target(path):
    valid_path(path)
    state = str(Path(state_runs()).parent)
    if path == state or path.startswith(state + '/'):
        raise UnsafeState('journal state is not an owned target')


def snapshot_file(run, module, path):
    owned_target(path)
    validate(dict(event='intent', module=module, path=path, before_sha256=None, intended_sha256='0' * 64))
    with parent_fd(path) as (parent, name), journal(run) as (fd, events):
        data, info = read_file(parent, name)
        snapshot_locked(fd, events, run, module, path, data, info)


def install_owned_file(run, module, source, target):
    owned_target(target)
    validate(dict(event='intent', module=module, path=target, before_sha256=None, intended_sha256='0' * 64))
    with parent_fd(source) as (parent, name):
        data, source_info = read_file(parent, name)
        if data is None:
            raise UnsafeState('missing source')
    with parent_fd(target) as (parent, name), journal(run) as (fd, events):
        before, info = read_file(parent, name)
        expected = None
        for event in events:
            if event.get('path') != target:
                continue
            if event['module'] != module:
                raise UnsafeState('file owned by another module')
            if event['event'] == 'snapshot':
                expected = {event['before_sha256']}
            elif event['event'] == 'applied':
                expected = {event['applied_sha256']}
            elif event['event'] == 'intent':
                expected = {event['before_sha256'], event['intended_sha256']}
        if expected is not None and digest(before) not in expected:
            raise UnsafeState('target changed since snapshot')
        if before == data:
            return
        snapshot_locked(fd, events, run, module, target, before, info)
        temp = '.vaio-' + uuid.uuid4().hex
        saved = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=parent)
        try:
            write_file(saved, data, info or source_info)
            append_event(fd, dict(event='intent', module=module, path=target,
                                  before_sha256=digest(before), intended_sha256=digest(data)))
            current, current_info = read_file(parent, name)
            if current != before or (info is not None and
                    (current_info.st_dev, current_info.st_ino, current_info.st_mode,
                     current_info.st_uid, current_info.st_gid, current_info.st_mtime_ns, current_info.st_ctime_ns)
                    != (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
                        info.st_mtime_ns, info.st_ctime_ns)):
                raise UnsafeState('target changed')
            os.replace(temp, name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
            append_event(fd, dict(event='applied', module=module, path=target, applied_sha256=digest(data)))
        finally:
            os.close(saved)
            try:
                os.unlink(temp, dir_fd=parent)
            except FileNotFoundError:
                pass


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('init')
    sub.add_parser('list')
    for command in ('verify', 'append', 'snapshot', 'install'):
        p = sub.add_parser(command)
        p.add_argument('run')
        if command == 'append':
            p.add_argument('event')
        if command in ('snapshot', 'install'):
            p.add_argument('module')
            p.add_argument('path')
        if command == 'install':
            p.add_argument('target')
    args = parser.parse_args()
    try:
        if args.command == 'init':
            print(begin_run())
        elif args.command == 'list':
            runs = state_runs()
            found = []
            try:
                with parent_fd(runs + '/entry') as (parent, _):
                    for run in sorted(os.listdir(parent)):
                        run_path(run)
                        with journal(run):
                            found.append(run)
            except FileNotFoundError:
                if os.path.lexists(runs):
                    raise
            print(json.dumps(found))
        elif args.command in ('verify', 'append'):
            with journal(args.run) as (fd, _):
                if args.command == 'append':
                    event = json.loads(args.event, object_pairs_hook=no_duplicates)
                    if isinstance(event, dict) and event.get('event') == 'run':
                        raise UnsafeState('duplicate run header')
                    append_event(fd, event)
        elif args.command == 'snapshot':
            snapshot_file(args.run, args.module, args.path)
        elif args.command == 'install':
            install_owned_file(args.run, args.module, args.path, args.target)
    except (OSError, ValueError, TypeError, KeyError):
        print('Erro: estado ou caminho inválido; operação interrompida.', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
