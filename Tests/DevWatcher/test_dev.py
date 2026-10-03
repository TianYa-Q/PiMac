import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts' / 'dev.py'
IMPORT = f"import importlib.util; s=importlib.util.spec_from_file_location('dev', {str(SCRIPT)!r}); d=importlib.util.module_from_spec(s); s.loader.exec_module(d)\n"


def wait_file(path):
    for _ in range(100):
        if path.exists():
            return int(path.read_text())
        time.sleep(0.05)
    raise AssertionError(f'Timed out waiting for {path}')


class DevWatcherTests(unittest.TestCase):
    def load_dev(self):
        spec = importlib.util.spec_from_file_location('dev', SCRIPT)
        dev = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dev)
        return dev

    def supervisor(self, dev, directory, code=None):
        state = Path(directory) / 'state'
        restart = Path(directory) / 'restart'
        supervisor = dev.AppSupervisor(Path('/fake/PiMac'), {}, state, restart, set())
        supervisor.app = Mock(pid=123)
        supervisor.app.poll.return_value = code
        return supervisor

    def test_restart_reaps_old_app_before_launching(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            supervisor = self.supervisor(dev, directory)
            supervisor.restart.write_text(json.dumps({'pid': 123, 'timestamp': time.time()}))
            with patch.object(supervisor, 'launch') as launch:
                supervisor.tick()
                launch.assert_not_called()
                supervisor.app.poll.return_value = 0
                supervisor.tick()
                supervisor.app.poll.assert_called()
                launch.assert_called_once()

    def test_real_child_handoff_preserves_logs_and_tracks_replacement(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            dev.app_log = directory / 'app.log'
            state, restart = directory / 'state', directory / 'restart'
            count = directory / 'count'
            binary = directory / 'fake-app'
            binary.write_text(f'''#!{sys.executable}
import json, os, pathlib, time
count = pathlib.Path({str(count)!r})
n = int(count.read_text()) + 1 if count.exists() else 1
count.write_text(str(n))
print('launch', n, flush=True)
pathlib.Path({str(state)!r}).write_text(json.dumps({{'pid': os.getpid(), 'timestamp': time.time(), 'idle': False}}))
if n == 1:
    pathlib.Path({str(restart)!r}).write_text(json.dumps({{'pid': os.getpid(), 'timestamp': time.time()}}))
else:
    time.sleep(60)
''')
            binary.chmod(0o700)
            groups = set()
            supervisor = dev.AppSupervisor(binary, os.environ.copy(), state, restart, groups)
            supervisor.launch()
            old = supervisor.app
            try:
                old.wait(timeout=5)
                supervisor.tick()
                replacement = supervisor.app
                self.assertNotEqual(old.pid, replacement.pid)
                for _ in range(100):
                    supervisor.tick()
                    if supervisor.startup_deadline is None:
                        break
                    time.sleep(0.02)
                self.assertIsNone(supervisor.startup_deadline)
                self.assertEqual(count.read_text(), '2')
                self.assertEqual(groups, {old.pid, replacement.pid})
                self.assertIn('launch 1', dev.app_log.read_text())
                self.assertIn('launch 2', dev.app_log.read_text())
                self.assertFalse(restart.exists())
            finally:
                if supervisor.app.poll() is None:
                    supervisor.app.terminate()
                supervisor.app.wait(timeout=5)

    def test_stale_wrong_pid_or_failed_exit_never_relaunches(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            for pid, stamp, code in [(124, time.time(), 0), (123, time.time() - 20, 0),
                                      (123, time.time(), 1)]:
                supervisor = self.supervisor(dev, directory, code)
                supervisor.restart.write_text(json.dumps({'pid': pid, 'timestamp': stamp}))
                with patch.object(supervisor, 'launch') as launch:
                    with self.assertRaises(RuntimeError):
                        supervisor.tick()
                    launch.assert_not_called()

    def test_exit_and_startup_waits_are_bounded(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            supervisor = self.supervisor(dev, directory)
            supervisor.restart.write_text(json.dumps({'pid': 123, 'timestamp': time.time()}))
            supervisor.exit_deadline = time.monotonic() - 1
            with self.assertRaisesRegex(RuntimeError, 'old app did not exit'):
                supervisor.tick()
            supervisor.restart.unlink()
            supervisor.exit_deadline = None
            supervisor.startup_deadline = time.monotonic() - 1
            with self.assertRaisesRegex(RuntimeError, 'heartbeat timed out'):
                supervisor.tick()

    def test_startup_requires_heartbeat_of_replacement_pid(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            supervisor = self.supervisor(dev, directory)
            supervisor.startup_deadline = time.monotonic() + 30
            supervisor.state.write_text(json.dumps({'pid': 122, 'timestamp': time.time()}))
            supervisor.tick()
            self.assertIsNotNone(supervisor.startup_deadline)
            supervisor.state.write_text(json.dumps({'pid': 123, 'timestamp': time.time()}))
            supervisor.tick()
            self.assertIsNone(supervisor.startup_deadline)

    def test_successful_build_output_goes_to_log(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            dev.build_log = Path(directory) / 'build.log'
            terminal = io.StringIO()
            with contextlib.redirect_stdout(terminal), contextlib.redirect_stderr(terminal):
                code, output = dev.run_build_command([
                    sys.executable, '-c', 'import sys; print("built"); print("warning", file=sys.stderr)'])
            self.assertEqual(code, 0)
            self.assertEqual(terminal.getvalue(), '')
            self.assertIn('built', output)
            self.assertIn('warning', dev.build_log.read_text())

    def test_failed_build_shows_tail_and_keeps_full_log(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            dev.build_log = Path(directory) / 'build.log'
            terminal = io.StringIO()
            with contextlib.redirect_stderr(terminal):
                code, _ = dev.run_build_command([
                    sys.executable, '-c', 'import sys; print("\\n".join(f"line {i}" for i in range(60))); sys.exit(1)'])
            self.assertEqual(code, 1)
            self.assertEqual(len(terminal.getvalue().splitlines()), 40)
            self.assertIn('line 0\n', dev.build_log.read_text())
            self.assertIn('line 59', terminal.getvalue())

    def test_verbose_build_output_is_visible(self):
        dev = self.load_dev()
        dev.verbose = True
        with tempfile.TemporaryDirectory() as directory:
            dev.build_log = Path(directory) / 'build.log'
            terminal = io.StringIO()
            with contextlib.redirect_stdout(terminal):
                dev.run_build_command([sys.executable, '-c', 'print("details")'])
            self.assertEqual(terminal.getvalue(), 'details\n')

    def test_development_bundle_has_notification_identity_icon_and_resources(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            dev.root = Path(directory)
            binary_dir = dev.root / 'debug'
            bundle = binary_dir / 'PiMac_PiMacApp.bundle'
            bundle.mkdir(parents=True)
            (bundle / 'resource').write_text('first')
            (binary_dir / 'PiMac').write_text('executable')
            (binary_dir / 'PiMac').chmod(0o755)
            icon = dev.root / 'Sources/PiMacApp/Resources/AppIcon.icns'
            icon.parent.mkdir(parents=True)
            icon.write_bytes(b'icon')
            with patch.object(dev, 'run_build_command', return_value=(0, '')) as command:
                binary = dev.bundle_development_app(binary_dir)
                contents = binary.parent.parent
                self.assertEqual(binary.read_text(), 'executable')
                self.assertTrue(os.access(binary, os.X_OK))
                with (contents / 'Info.plist').open('rb') as file:
                    info = plistlib.load(file)
                self.assertEqual(info['CFBundleIdentifier'], 'com.jianfeng.pi-mac.dev')
                self.assertEqual(info['CFBundleIconFile'], 'AppIcon')
                self.assertEqual((contents / 'Resources/AppIcon.icns').read_bytes(), b'icon')
                copied = contents / 'Resources/PiMac_PiMacApp.bundle'
                self.assertEqual((copied / 'resource').read_text(), 'first')
                (copied / 'obsolete').touch()
                (bundle / 'resource').write_text('second')
                (binary_dir / 'PiMac').write_text('new executable')
                self.assertEqual(dev.bundle_development_app(binary_dir), binary)
                self.assertEqual(binary.read_text(), 'new executable')
                self.assertEqual((copied / 'resource').read_text(), 'second')
                self.assertFalse((copied / 'obsolete').exists())
                self.assertEqual(command.call_args_list[0].args[0][0], 'codesign')
                self.assertEqual(command.call_args_list[1].args[0][-2:], ['-f', str(contents.parent)])

    def test_running_apps_matches_bundle_paths_with_spaces_and_old_debug_app(self):
        dev = self.load_dev()
        binary = dev.root / '.build/Pi Mac Dev.app/Contents/MacOS/PiMac'
        processes = (f'101 {binary}\n102 {dev.root}/.build/debug/PiMac\n'
                     '103 /Applications/Pi Mac.app/Contents/MacOS/PiMac\n')
        with patch.object(dev.subprocess, 'check_output', return_value=processes):
            self.assertEqual(dev.running_apps(binary), [101, 102])

    def test_development_bundle_signing_failure_does_not_return_binary(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            dev.root = Path(directory)
            binary_dir = dev.root / 'debug'
            (binary_dir / 'PiMac_PiMacApp.bundle').mkdir(parents=True)
            (binary_dir / 'PiMac').touch()
            icon = dev.root / 'Sources/PiMacApp/Resources/AppIcon.icns'
            icon.parent.mkdir(parents=True)
            icon.touch()
            with patch.object(dev, 'run_build_command', return_value=(1, '')):
                self.assertIsNone(dev.bundle_development_app(binary_dir))

    def test_change_summary_includes_added_modified_and_removed_files(self):
        dev = self.load_dev()
        before = [(str(dev.root / 'removed.swift'), 1, 1),
                  (str(dev.root / 'changed.swift'), 1, 1)]
        after = [(str(dev.root / 'added.swift'), 1, 1),
                 (str(dev.root / 'changed.swift'), 2, 1)]
        self.assertEqual(dev.changed_files(before, after),
                         ['added.swift', 'changed.swift', 'removed.swift'])

    def test_idle_heartbeat_fails_closed(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / 'state.json'
            self.assertFalse(dev.app_is_idle(state))
            for content in ('bad json', '{}', json.dumps({'timestamp': time.time() - 10, 'idle': True}),
                            json.dumps({'timestamp': time.time(), 'idle': False})):
                state.write_text(content)
                self.assertFalse(dev.app_is_idle(state))
            state.write_text(json.dumps({'timestamp': time.time(), 'idle': True}))
            self.assertTrue(dev.app_is_idle(state))

    def test_pending_changes_coalesce_until_idle(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / 'request'
            revision = Path(directory) / 'revision'
            pending = dev.PendingBuild((), request, revision)
            first = ((str(dev.root / 'a.swift'), 1, 1),)
            latest = ((str(dev.root / 'a.swift'), 2, 1),)
            with patch.object(dev, 'snapshot', return_value=first) as snapshot, \
                    patch.object(dev, 'app_is_idle', return_value=False) as idle, \
                    patch.object(dev, 'build', return_value=Path('PiMac')) as build, \
                    patch.object(dev.time, 'monotonic', return_value=10) as clock:
                pending.tick(None)
                snapshot.return_value = latest
                clock.return_value = 11
                pending.tick(None)
                clock.return_value = 20
                pending.tick(None)
                build.assert_not_called()
                self.assertTrue(request.exists())
                idle.return_value = True
                pending.tick(None)
                build.assert_called_once()
                self.assertTrue(revision.exists())
                self.assertFalse(request.exists())
                pending.tick(None)
                build.assert_called_once()

    def test_build_failure_does_not_reload_or_retry_without_edits(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / 'request'
            revision = Path(directory) / 'revision'
            pending = dev.PendingBuild((), request, revision)
            current = ((str(dev.root / 'a.swift'), 1, 1),)
            pending.observe(current)
            pending.changed_at = time.monotonic() - 1
            with patch.object(dev, 'snapshot', return_value=current), \
                    patch.object(dev, 'app_is_idle', return_value=True), \
                    patch.object(dev, 'build', return_value=None) as build:
                pending.tick(None)
                pending.tick(None)
                build.assert_called_once()
                self.assertFalse(revision.exists())
                self.assertFalse(pending.dirty)

    def test_edits_during_build_defer_reload(self):
        dev = self.load_dev()
        with tempfile.TemporaryDirectory() as directory:
            request = Path(directory) / 'request'
            revision = Path(directory) / 'revision'
            pending = dev.PendingBuild((), request, revision)
            first = ((str(dev.root / 'a.swift'), 1, 1),)
            latest = ((str(dev.root / 'a.swift'), 2, 1),)
            pending.observe(first)
            pending.changed_at = time.monotonic() - 1
            with patch.object(dev, 'snapshot', side_effect=[first, latest]), \
                    patch.object(dev, 'app_is_idle', return_value=True), \
                    patch.object(dev, 'build', return_value=Path('PiMac')):
                pending.tick(None)
                self.assertFalse(revision.exists())
                self.assertTrue(request.exists())
                self.assertTrue(pending.dirty)
                self.assertEqual(pending.previous, latest)

    def test_ctrl_c_cancels_build_process_group(self):
        with tempfile.TemporaryDirectory() as directory:
            pid_file = Path(directory) / 'build-pid'
            child = f"import os, time; open({str(pid_file)!r}, 'w').write(str(os.getpid())); time.sleep(60)"
            source = IMPORT + f"try:\n d.run_build_command([{sys.executable!r}, '-c', {child!r}])\nexcept KeyboardInterrupt:\n raise SystemExit(130)\n"
            watcher = subprocess.Popen([sys.executable, '-c', source], start_new_session=True)
            child_pid = None
            try:
                child_pid = wait_file(pid_file)
                watcher.send_signal(signal.SIGINT)
                self.assertEqual(watcher.wait(timeout=5), 130)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child_pid, 0)
            finally:
                if watcher.poll() is None:
                    watcher.kill()
                    watcher.wait()
                if child_pid:
                    try:
                        os.killpg(child_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_ctrl_c_stops_app_and_detached_service(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / '.build').mkdir()
            pid_file = root / 'app-pid'
            binary = root / 'fake-app'
            service_file = root / 'service-pid'
            service = f'import os, time; open({str(service_file)!r}, "w").write(str(os.getpid())); time.sleep(60)'
            binary.write_text(f'#!{sys.executable}\nimport os, time, subprocess\nsubprocess.Popen([{sys.executable!r}, "-c", {service!r}], start_new_session=True)\nopen({str(pid_file)!r}, "w").write(str(os.getpid()))\ntime.sleep(60)\n')
            binary.chmod(0o700)
            source = IMPORT + f"d.root=d.Path({directory!r}); d.build_log=d.root/'.build/dev-build.log'; d.app_log=d.root/'.build/dev-app.log'; d.build=lambda: d.Path({str(binary)!r}); d.running_apps=lambda _: []\ntry:\n d.main()\nexcept KeyboardInterrupt:\n raise SystemExit(130)\n"
            watcher = subprocess.Popen([sys.executable, '-c', source], start_new_session=True,
                                       stdout=subprocess.DEVNULL)
            app_pid = None
            try:
                app_pid = wait_file(pid_file)
                service_pid = wait_file(service_file)
                # Match terminal Ctrl-C: send to the whole foreground group.
                os.killpg(watcher.pid, signal.SIGINT)
                self.assertEqual(watcher.wait(timeout=5), 130)
                for pid in (app_pid, service_pid):
                    for _ in range(50):
                        try:
                            os.kill(pid, 0)
                        except ProcessLookupError:
                            break
                        time.sleep(0.05)
                    else:
                        self.fail(f'Process {pid} survived watcher shutdown')
            finally:
                if watcher.poll() is None:
                    watcher.kill()
                    watcher.wait()
                if app_pid:
                    try:
                        os.killpg(app_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_cleanup_finds_relaunch_orphans_but_not_unrelated_processes(self):
        spec = importlib.util.spec_from_file_location('dev', SCRIPT)
        dev = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dev)
        table = {
            101: (1, 101, str(dev.root / '.build/debug/PiMac')),
            102: (101, 102, 'pi --mode rpc'),
            103: (1, 103, 'node ' + str(dev.root / '.build/debug/PiMac_PiMacApp.bundle/t3-bridge/server-gateway.mjs')),
            104: (103, 104, '/somewhere/cloudflared tunnel'),
            105: (1, 99, 'orphaned-service'),
            106: (1, 106, 'pi --mode rpc'),
            107: (1, 107, '/Applications/Other.app/Contents/MacOS/PiMac'),
            108: (1, 108, '/bin/bash -c echo ' + str(dev.root / 'Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs')),
        }
        self.assertEqual(dev.owned_processes(table, {99}), {101, 102, 103, 104, 105})

    def test_snapshot_excludes_dependencies_and_includes_backend(self):
        spec = importlib.util.spec_from_file_location('dev', SCRIPT)
        dev = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(dev)
        with tempfile.TemporaryDirectory() as directory:
            dev.root = Path(directory)
            (dev.root / 'Package.swift').touch()
            server = dev.root / 'sidecars/t3-server'
            (server / 'node_modules/deep').mkdir(parents=True)
            (server / 'node_modules/deep/ignored.ts').touch()
            (server / 'runtime.mjs').touch()
            paths = [item[0] for item in dev.snapshot()]
            self.assertIn(str(server / 'runtime.mjs'), paths)
            self.assertFalse(any('node_modules' in path for path in paths))


if __name__ == '__main__':
    unittest.main()
