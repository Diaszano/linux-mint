#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'lib/manifest.py'


class ManifestTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.env = dict(os.environ, XDG_STATE_HOME=str(self.base / 'state'))

    def cli(self, *args):
        return subprocess.run(['python3', str(HELPER), *map(str, args)], env=self.env,
                              text=True, capture_output=True)

    def begin(self):
        result = self.cli('init')
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def journal(self, run):
        return self.base / 'state/vaio-fe16-dev-setup/runs' / run / 'manifest.jsonl'

    def events(self, run):
        return [json.loads(line) for line in self.journal(run).read_text().splitlines()]

    def test_private_run_modes_do_not_depend_on_callers_umask(self):
        result = subprocess.run(['python3', str(HELPER), 'init'], env=self.env,
                                text=True, capture_output=True, umask=0o777)
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = self.journal(result.stdout.strip())
        self.assertEqual(stat.S_IMODE(manifest.stat().st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(manifest.parent.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((manifest.parent / 'backups').stat().st_mode), 0o700)

    def test_listing_before_first_run_is_read_only_and_empty(self):
        result = self.cli('list')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [])
        self.assertFalse((self.base / 'state').exists())

    def test_runs_are_unique_private_and_verifiable(self):
        first, second = self.begin(), self.begin()
        self.assertNotEqual(first, second)
        for run in (first, second):
            manifest = self.journal(run)
            self.assertEqual(stat.S_IMODE(manifest.parent.stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE((manifest.parent / 'backups').stat().st_mode), 0o700)
            self.assertEqual(stat.S_IMODE(manifest.stat().st_mode), 0o600)
            self.assertEqual(self.cli('verify', run).returncode, 0)
        self.assertEqual(json.loads(self.cli('list').stdout), [first, second])

    def test_append_rejects_foreign_backup_without_changing_journal(self):
        run = self.begin()
        target = self.base / 'target'
        target.write_text('original')
        self.assertEqual(self.cli('snapshot', run, 'baseline', target).returncode, 0)
        event = self.events(run)[-1]
        before = self.journal(run).read_bytes()
        for backup in ('/tmp/x', str(self.journal(run).parent / 'backups' / ('f' * 32))):
            event['backup'] = backup
            result = self.cli('append', run, json.dumps(event))
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.journal(run).read_bytes(), before)
            self.assertEqual(self.cli('verify', run).returncode, 0)

    def test_interrupted_initialization_does_not_hide_healthy_runs(self):
        healthy = self.begin()
        spec = importlib.util.spec_from_file_location('manifest', HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with patch.dict(os.environ, self.env), patch.object(module, 'append_event', side_effect=KeyboardInterrupt):
            with self.assertRaises(KeyboardInterrupt):
                module.begin_run()
        result = self.cli('list')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), [healthy])
        self.assertIn('incompleta', result.stderr)
        self.assertEqual(self.cli('verify', healthy).returncode, 0)
        incomplete = [p.name for p in self.journal(healthy).parent.parent.iterdir() if p.name != healthy]
        self.assertEqual(len(incomplete), 1)
        self.assertEqual(self.journal(incomplete[0]).read_bytes(), b'')

    def test_append_rejects_content_unknown_keys_invalid_paths_and_corruption(self):
        run = self.begin()
        before = self.journal(run).read_bytes()
        for event in ({'event': 'secret', 'content': 'password'},
                      {'event': 'intent', 'module': 'base', 'path': '../escape'},
                      {'event': 'run', 'run_id': run, 'password': 'secret'}):
            result = self.cli('append', run, json.dumps(event))
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('password', result.stderr)
            self.assertEqual(self.journal(run).read_bytes(), before)
        with self.journal(run).open('ab') as stream:
            stream.write(b'{"event":')
        self.assertNotEqual(self.cli('verify', run).returncode, 0)
        self.assertNotEqual(self.cli('append', run, json.dumps({'event': 'run', 'run_id': run})).returncode, 0)

    def test_snapshot_preserves_bytes_owner_mode_and_creation(self):
        run = self.begin()
        target = self.base / 'a "quoted" name'
        target.write_bytes(b'private-password\x00bytes')
        target.chmod(0o640)
        self.assertEqual(self.cli('snapshot', run, 'baseline', target).returncode, 0)
        snapshot = self.events(run)[-1]
        saved = Path(snapshot['backup'])
        self.assertEqual(saved.read_bytes(), target.read_bytes())
        self.assertEqual((saved.stat().st_uid, saved.stat().st_gid, stat.S_IMODE(saved.stat().st_mode)),
                         (target.stat().st_uid, target.stat().st_gid, 0o640))
        self.assertNotIn('private-password', self.journal(run).read_text())
        self.assertEqual(self.cli('snapshot', run, 'baseline', self.base / 'absent').returncode, 0)
        self.assertIsNone(self.events(run)[-1]['before_sha256'])
        self.assertIsNone(self.events(run)[-1]['backup'])

    def test_atomic_install_is_idempotent_and_preserves_existing_metadata(self):
        run = self.begin()
        source, target = self.base / 'source', self.base / 'target'
        source.write_text('new secret')
        target.write_text('old secret')
        target.chmod(0o640)
        self.assertEqual(self.cli('install', run, 'baseline', source, target).returncode, 0)
        self.assertEqual(target.read_text(), 'new secret')
        self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o640)
        inode, journal = target.stat().st_ino, self.journal(run).read_bytes()
        self.assertEqual(self.cli('install', run, 'baseline', source, target).returncode, 0)
        self.assertEqual((target.stat().st_ino, self.journal(run).read_bytes()), (inode, journal))
        events = self.events(run)
        self.assertEqual([e['event'] for e in events], ['run', 'snapshot', 'intent', 'applied'])
        self.assertEqual(events[-2]['intended_sha256'], events[-1]['applied_sha256'])
        self.assertNotIn('secret', self.journal(run).read_text())

    def test_unsafe_paths_and_symlinks_are_refused_without_writes(self):
        run = self.begin()
        source = self.base / 'source'
        source.write_text('new')
        real = self.base / 'real'
        real.mkdir()
        (self.base / 'link').symlink_to(real, target_is_directory=True)
        (real / 'link').symlink_to(source)
        before = self.journal(run).read_bytes()
        for path in ('relative', str(self.base / 'bad\nname'), str(self.base) + '/../escape',
                     str(self.base / 'link/file'), str(real / 'link'), str(real)):
            result = self.cli('install', run, 'baseline', source, path)
            self.assertNotEqual(result.returncode, 0, path)
            self.assertEqual(self.journal(run).read_bytes(), before)
        self.assertNotEqual(self.cli('verify', '../escape').returncode, 0)
        self.assertNotEqual(self.cli('snapshot', run, 'bad\nmodule', source).returncode, 0)
        self.assertNotEqual(self.cli('install', run, 'baseline', real / 'link', real / 'new').returncode, 0)

    def test_interrupted_replace_has_fsynced_intent_and_original_backup(self):
        self.assertTrue(HELPER.exists(), 'manifest helper is missing')
        spec = importlib.util.spec_from_file_location('manifest', HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source, target = self.base / 'source', self.base / 'target'
        source.write_text('complete-new')
        target.write_text('complete-old')
        with patch.dict(os.environ, self.env):
            run = module.begin_run()
            actual_fsync = module.os.fsync
            flushed = []
            def fsync(fd):
                actual_fsync(fd)
                if Path(f'/proc/self/fd/{fd}').resolve() == self.journal(run):
                    flushed.append(self.events(run)[-1]['event'])
            def interrupt(*args, **kwargs):
                self.assertIn('intent', flushed)
                self.assertEqual(self.events(run)[-1]['event'], 'intent')
                self.assertEqual(target.read_text(), 'complete-old')
                raise KeyboardInterrupt
            with patch.object(module.os, 'fsync', side_effect=fsync), patch.object(module.os, 'replace', side_effect=interrupt):
                with self.assertRaises(KeyboardInterrupt):
                    module.install_owned_file(run, 'baseline', str(source), str(target))
        self.assertEqual(target.read_text(), 'complete-old')
        snapshot = self.events(run)[1]
        self.assertEqual(Path(snapshot['backup']).read_text(), 'complete-old')
        self.assertEqual(self.cli('verify', run).returncode, 0)
        self.assertEqual(sorted(p.name for p in self.base.iterdir()), ['source', 'state', 'target'])

    def test_owned_writes_cannot_overwrite_journal_or_backups(self):
        run = self.begin()
        source = self.base / 'source'
        source.write_text('private secret')
        before = self.journal(run).read_bytes()
        for target in (self.journal(run), self.journal(run).parent / 'backups/new'):
            self.assertNotEqual(self.cli('install', run, 'baseline', source, target).returncode, 0)
            self.assertNotEqual(self.cli('snapshot', run, 'baseline', target).returncode, 0)
            self.assertEqual(self.journal(run).read_bytes(), before)

    def test_failed_intent_flush_never_replaces_target(self):
        self.assertTrue(HELPER.exists(), 'manifest helper is missing')
        spec = importlib.util.spec_from_file_location('manifest', HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source, target = self.base / 'source', self.base / 'target'
        source.write_text('new')
        target.write_text('old')
        with patch.dict(os.environ, self.env):
            run = module.begin_run()
            fsync = module.os.fsync
            def fail_intent(fd):
                if Path(f'/proc/self/fd/{fd}').resolve() == self.journal(run) and self.events(run)[-1]['event'] == 'intent':
                    raise OSError('simulated flush failure')
                fsync(fd)
            with patch.object(module.os, 'fsync', side_effect=fail_intent):
                with self.assertRaises(OSError):
                    module.install_owned_file(run, 'baseline', str(source), str(target))
        self.assertEqual(target.read_text(), 'old')
        self.assertEqual(sorted(p.name for p in self.base.iterdir()), ['source', 'state', 'target'])

    def test_same_run_refuses_later_user_edits_and_cross_module_claims(self):
        run = self.begin()
        source, target = self.base / 'source', self.base / 'target'
        source.write_text('new')
        target.write_text('original')
        self.assertEqual(self.cli('snapshot', run, 'baseline', target).returncode, 0)
        target.write_text('user edit')
        self.assertNotEqual(self.cli('install', run, 'baseline', source, target).returncode, 0)
        self.assertEqual(target.read_text(), 'user edit')
        self.assertNotEqual(self.cli('snapshot', run, 'other', target).returncode, 0)

    def test_snapshot_does_not_accept_modified_or_missing_backup(self):
        run = self.begin()
        target = self.base / 'target'
        target.write_text('original')
        self.assertEqual(self.cli('snapshot', run, 'baseline', target).returncode, 0)
        backup = Path(self.events(run)[-1]['backup'])
        backup.write_text('corrupted')
        self.assertNotEqual(self.cli('snapshot', run, 'baseline', target).returncode, 0)
        self.assertNotEqual(self.cli('verify', run).returncode, 0)
        backup.unlink()
        self.assertNotEqual(self.cli('verify', run).returncode, 0)

    def test_replacement_with_failed_applied_append_is_recoverable(self):
        self.assertTrue(HELPER.exists(), 'manifest helper is missing')
        spec = importlib.util.spec_from_file_location('manifest', HELPER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        source, target = self.base / 'source', self.base / 'target'
        source.write_text('new')
        target.write_text('old')
        with patch.dict(os.environ, self.env):
            run = module.begin_run()
            append = module.append_event
            def fail_applied(fd, event):
                if event['event'] == 'applied':
                    raise OSError('simulated full disk')
                append(fd, event)
            with patch.object(module, 'append_event', side_effect=fail_applied):
                with self.assertRaises(OSError):
                    module.install_owned_file(run, 'baseline', str(source), str(target))
        self.assertEqual(target.read_text(), 'new')
        self.assertEqual(self.events(run)[-1]['event'], 'intent')
        self.assertEqual(self.cli('verify', run).returncode, 0)


if __name__ == '__main__':
    unittest.main()
