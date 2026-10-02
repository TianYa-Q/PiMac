import contextlib
import importlib.util
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

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

    def test_change_summary_includes_added_modified_and_removed_files(self):
        dev = self.load_dev()
        before = [(str(dev.root / 'removed.swift'), 1, 1),
                  (str(dev.root / 'changed.swift'), 1, 1)]
        after = [(str(dev.root / 'added.swift'), 1, 1),
                 (str(dev.root / 'changed.swift'), 2, 1)]
        self.assertEqual(dev.changed_files(before, after),
                         ['added.swift', 'changed.swift', 'removed.swift'])

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
