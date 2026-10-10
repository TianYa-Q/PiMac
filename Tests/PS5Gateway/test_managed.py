import contextlib
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import gateway

# Load definitions only. Never run managed_main or any privileged operation.
namespace = dict(vars(gateway))
source = (Path(gateway.__file__).parent / 'managed.py').read_text()
exec(compile(source.rsplit('\nmanaged_main()', 1)[0], '<managed-tests>', 'exec'), namespace)


class ManagedSessionTest(unittest.TestCase):
    def run_session(self, alive, check=None, emit=None, write=None):
        values = {gateway.FORWARD: '0', gateway.REDIRECT: '1'}
        events = []
        def default_write(key, value):
            if write:
                write(key, value)
            values[key] = value
        with patch.dict(namespace, {'exclusive_session': contextlib.nullcontext}):
            namespace['managed_session'](
                alive, emit or (lambda phase, detail='', identity=None: events.append((phase, detail))),
                check=check or (lambda: ('42', 'utun4')), read=values.__getitem__,
                session_factory=lambda: gateway.Session(values.__getitem__, default_write),
                sleep=lambda _: None)
        return values, events

    def test_active_only_after_checks_and_stop_restores(self):
        alive = iter([True, True, True, False])
        values, events = self.run_session(lambda: next(alive))
        self.assertEqual([p for p, _ in events], ['active', 'stopping', 'stopped'])
        self.assertEqual(values, {gateway.FORWARD: '0', gateway.REDIRECT: '1'})

    def test_expired_before_start_never_modifies_parameters(self):
        writes = []
        _, events = self.run_session(lambda: False, write=lambda *args: writes.append(args))
        self.assertEqual(writes, [])
        self.assertEqual(events[-1][0], 'error')

    def test_tun_change_restores_and_reports_error_not_active(self):
        checks = iter([('42', 'utun4'), ('43', 'utun4')])
        values, events = self.run_session(lambda: True, check=lambda: next(checks))
        self.assertNotIn('active', [p for p, _ in events])
        self.assertEqual(events[-1][0], 'error')
        self.assertEqual(values[gateway.FORWARD], '0')

    def test_status_publish_failure_still_restores(self):
        writes = []
        def emit(phase, detail='', identity=None):
            if phase in ('active', 'stopping'):
                raise RuntimeError('disk full')
        _, _ = self.run_session(lambda: True, emit=emit,
                               write=lambda key, value: writes.append((key, value)))
        self.assertIn((gateway.FORWARD, '0'), writes)
        self.assertIn((gateway.REDIRECT, '1'), writes)

    def test_restore_failure_is_error(self):
        values = {gateway.FORWARD: '0', gateway.REDIRECT: '1'}
        events = []
        alive = iter([True, True, True, False])
        def write(key, value):
            if key == gateway.FORWARD and value == '0':
                raise RuntimeError('restore denied')
            values[key] = value
        with patch.dict(namespace, {'exclusive_session': contextlib.nullcontext}):
            namespace['managed_session'](
                lambda: next(alive), lambda phase, detail='', identity=None: events.append((phase, detail)),
                check=lambda: ('42', 'utun4'), read=values.__getitem__,
                session_factory=lambda: gateway.Session(values.__getitem__, write), sleep=lambda _: None)
        self.assertEqual(events[-1][0], 'error')
        self.assertIn('Restore needs attention', events[-1][1])
        self.assertEqual(values[gateway.FORWARD], '1')

    def test_lease_missing_stale_wrong_owner_or_symlink_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'heartbeat'
            alive = namespace['lease_alive']
            self.assertFalse(alive(str(path), os.getpid(), os.getuid()))
            path.touch()
            self.assertTrue(alive(str(path), os.getpid(), os.getuid()))
            self.assertFalse(alive(str(path), os.getpid(), os.getuid() + 1))
            os.utime(path, (time.time() - 30, time.time() - 30))
            self.assertFalse(alive(str(path), os.getpid(), os.getuid()))
            link = Path(folder) / 'link'
            link.symlink_to(path)
            self.assertFalse(alive(str(link), os.getpid(), os.getuid()))

    def test_status_is_atomically_published(self):
        import json
        with tempfile.TemporaryDirectory() as folder:
            namespace['publish'](folder, 'active', identity=('42', 'utun4'))
            result = json.loads((Path(folder) / 'status.json').read_text())
            self.assertEqual(result['tun'], 'utun4')
            self.assertEqual(result['phase'], 'active')
            self.assertFalse((Path(folder) / 'status.next').exists())


if __name__ == '__main__':
    unittest.main()
