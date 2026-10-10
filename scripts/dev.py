#!/usr/bin/env python3
"""Coalesce source changes; build when Pi Mac is idle, then safely relaunch."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import signal
import sys
import uuid
import tempfile
import time

root = Path(__file__).resolve().parent.parent
os.chdir(root)

verbose = False
build_log = root / ".build" / "dev-build.log"
app_log = root / ".build" / "dev-app.log"
build_number = 0


def status(message):
    line = f"[{time.strftime('%Y-%m-%d %H:%M:%S')}] {message}"
    print(line, flush=True)
    try:
        app_log.parent.mkdir(parents=True, exist_ok=True)
        with (app_log.parent / 'dev-watch.log').open('a') as log:
            log.write(line + '\n')
    except OSError:
        pass  # Diagnostics must not break shutdown.


def changed_files(previous, current):
    before = {path: (mtime, size) for path, mtime, size in previous}
    after = {path: (mtime, size) for path, mtime, size in current}
    return sorted(Path(path).relative_to(root).as_posix()
                  for path in before.keys() | after.keys()
                  if before.get(path) != after.get(path))


def snapshot():
    """Fingerprint runtime inputs, not save times, tests or development tooling."""
    paths = [root / "Package.swift"]
    excluded = {"node_modules", "upstream", "generated", "vendor", "__pycache__", "tests"}
    for directory in ("Sources", "sidecars/t3-server", "extensions"):
        # Prune before descending, not after rglob has traversed dependencies.
        for base, directories, files in os.walk(root / directory):
            directories[:] = [name for name in directories if name not in excluded]
            for name in files:
                path = Path(base) / name
                if path.suffix in {".swift", ".mjs", ".js", ".ts", ".json", ".png", ".icns"}:
                    paths.append(path)
    result = []
    for path in set(paths):
        try:
            content = path.read_bytes()
            result.append((str(path), hashlib.sha256(content).hexdigest(), len(content)))
        except FileNotFoundError:
            pass  # An editor can replace a file during a scan.
    return tuple(sorted(result))


def read_state(path):
    try:
        data = json.loads(path.read_text())
        return data if isinstance(data, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}


class AppSupervisor:
    """The only launcher: reap the old child before starting a replacement."""
    def __init__(self, binary, env, state, restart, app_groups):
        self.binary, self.env = binary, env
        self.state, self.restart, self.app_groups = state, restart, app_groups
        self.app = None
        self.exit_deadline = None
        self.startup_deadline = None
        self.recovery_deadline = None
        self.recovery_attempts = 0
        self.launched_at = None

    def launch(self):
        self.state.unlink(missing_ok=True)
        self.restart.unlink(missing_ok=True)
        app_log.parent.mkdir(parents=True, exist_ok=True)
        with app_log.open("a") as log:
            log.write(f"\n--- App launch {time.strftime('%Y-%m-%d %H:%M:%S')} ---\n")
            log.flush()
            self.app = subprocess.Popen(
                [str(self.binary)], env=self.env, start_new_session=True,
                stdin=subprocess.DEVNULL, stdout=None if verbose else log,
                stderr=None if verbose else subprocess.STDOUT)
        self.app_groups.add(self.app.pid)
        self.launched_at = time.monotonic()
        self.startup_deadline = self.launched_at + 30
        self.exit_deadline = None
        self.recovery_deadline = None
        status(f"Pi Mac started · PID {self.app.pid}")

    def recover(self, reason):
        # Capture/stop surviving services before launching another owner.
        status(f"{reason} · cleaning up before automatic restart")
        cleanup(self.app_groups)
        self.state.unlink(missing_ok=True)
        if self.launched_at is not None and time.monotonic() - self.launched_at >= 60:
            self.recovery_attempts = 0
        self.recovery_attempts += 1
        delay = 2 ** min(self.recovery_attempts - 1, 5)
        self.recovery_deadline = time.monotonic() + delay
        status(f"Automatic restart in {delay}s · attempt {self.recovery_attempts}")

    def tick(self):
        if self.recovery_deadline is not None:
            if time.monotonic() >= self.recovery_deadline:
                self.launch()
            return
        code = self.app.poll()  # Reap zombies; kill -0 cannot do this.
        intent = read_state(self.restart)
        timestamp = intent.get("timestamp")
        valid = (intent.get("pid") == self.app.pid
                 and isinstance(timestamp, (int, float))
                 and 0 <= time.time() - timestamp <= 15)
        if code is not None:
            if not valid or code != 0:
                self.recover(f"Pi Mac exited ({code}) without a valid restart handoff; see {app_log}")
                return
            status(f"Old app reaped · PID {self.app.pid} · starting replacement")
            self.launch()
            return
        if valid:
            if self.exit_deadline is None:
                self.exit_deadline = time.monotonic() + 12
                status(f"Restart handoff received · waiting for PID {self.app.pid} to exit")
            if time.monotonic() >= self.exit_deadline:
                self.recover("Restart timed out: old app did not exit")
            return
        if self.exit_deadline is not None:
            self.recover("Restart handoff cancelled or expired")
            return
        if self.startup_deadline is not None:
            heartbeat = read_state(self.state)
            stamp = heartbeat.get("timestamp")
            if (heartbeat.get("pid") == self.app.pid
                    and isinstance(stamp, (int, float)) and 0 <= time.time() - stamp <= 3):
                self.startup_deadline = None
                status(f"App heartbeat confirmed · PID {self.app.pid}")
            elif time.monotonic() >= self.startup_deadline:
                self.recover(f"New app heartbeat timed out; see {app_log}")


def atomic_write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        temporary.write_text(text)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


def edit_directory():
    return root / '.build' / 'dev-edits'


def edit_blockers():
    # Explicit transactions do not expire merely because the editor/agent went quiet.
    try:
        return sorted(path.stem for path in edit_directory().iterdir() if path.suffix == '.json')
    except FileNotFoundError:
        return []
    except OSError:
        return ['unreadable-edit-barrier']  # Fail closed instead of silently ignoring it.


def begin_edit(label):
    token = uuid.uuid4().hex
    atomic_write(edit_directory() / (token + '.json'), json.dumps({
        'label': label, 'startedAt': time.time(), 'token': token,
    }))
    return token


def end_edit(token):
    if len(token) != 32 or any(char not in '0123456789abcdef' for char in token):
        raise ValueError('Invalid edit token')
    path = edit_directory() / (token + '.json')
    if not path.exists():
        raise ValueError('Unknown edit token; no other edit batches were changed')
    path.unlink()


def active_development_processes():
    """External builds/tests are real work, even if the app currently looks idle."""
    table = process_table()
    candidates = []
    for pid, (_, _, command) in table.items():
        executable = Path(command.split(' ', 1)[0]).name
        swift_work = executable in {'swift-build', 'swift-test', 'swiftpm-testing-helper'}
        node_work = (executable == 'node' and (' --test' in command
                     or any(part.endswith(('build.mjs', 'build-client.mjs'))
                            for part in command.split()[1:])))
        if not (swift_work or node_work):
            continue
        # Own build descendants are excluded; the watcher serializes those itself.
        parent = pid
        visited = set()
        while parent in table and parent not in visited and parent != os.getpid():
            visited.add(parent)
            parent = table[parent][0]
        if parent == os.getpid():
            continue
        try:
            output = subprocess.check_output(
                ['lsof', '-a', '-p', str(pid), '-d', 'cwd', '-Fn'],
                text=True, stderr=subprocess.DEVNULL, timeout=2)
            cwd = next((Path(line[1:]) for line in output.splitlines() if line.startswith('n')), None)
        except subprocess.CalledProcessError:
            # The process may have exited between ps and lsof.
            continue
        except (OSError, subprocess.TimeoutExpired):
            # An unresolved candidate must not authorize a reload.
            candidates.append(pid)
            continue
        if cwd is not None and (cwd == root or root in cwd.parents):
            candidates.append(pid)
    return candidates


def development_blockers():
    edits = edit_blockers()
    if edits:
        return ['unfinished edit batches: ' + ', '.join(edits)]
    work = active_development_processes()
    return ['external build/test processes: ' + ', '.join(map(str, work))] if work else []


def app_is_idle(state, expected_pid=None):
    """Fail closed if the app heartbeat is missing, stale, or malformed."""
    try:
        data = json.loads(state.read_text())
        age = time.time() - data["timestamp"]
        return (data["idle"] is True and 0 <= age <= 3
                and (expected_pid is None or data.get('pid') == expected_pid)
                and (data.get('phase') == 'watching' if expected_pid is not None
                     else data.get('phase', 'watching') == 'watching'))
    except (OSError, ValueError, KeyError, TypeError):
        return False


class PendingBuild:
    def __init__(self, previous, request, revision, expected_pid=None):
        self.expected_pid = expected_pid
        self.blocked_reason = None
        self.ready = None
        self.previous = previous
        self.applied = previous
        self.request = request
        self.revision = revision
        self.dirty = False
        self.changed_at = 0

    def observe(self, current):
        if current == self.previous:
            return
        changes = changed_files(self.previous, current)
        self.previous = current
        self.ready = None
        if current == self.applied:
            self.dirty = False
            self.request.unlink(missing_ok=True)
            status('Runtime changes reverted · no build or reload needed')
            return
        self.dirty = True
        self.changed_at = time.monotonic()
        atomic_write(self.request, str(time.time_ns()))
        preview = ", ".join(changes[:3])
        if len(changes) > 3:
            preview += f" (+{len(changes) - 3} more)"
        status(f"Changed · {preview} · waiting for idle before building")

    def tick(self, state):
        self.observe(snapshot())
        if not self.dirty:
            return
        blockers = development_blockers()
        if blockers:
            reason = '; '.join(blockers)
            if reason != self.blocked_reason:
                status('Reload blocked · ' + reason)
                self.blocked_reason = reason
            return
        self.blocked_reason = None
        if not app_is_idle(state, self.expected_pid):
            return
        built = self.ready if self.ready is not None else build()
        current = snapshot()
        if current != self.previous:
            self.observe(current)
            status("Sources changed during build · defer reload and build again when idle")
            return
        # A build is not permission to reload: revalidate development work and
        # the SAME app owner after the potentially long build.
        self.ready = built
        if built is not None and (development_blockers()
                                  or not app_is_idle(state, self.expected_pid)):
            status('Build ready but reload blocked · revalidate on next idle check')
            return
        # A failed build is retried only after another edit, not every idle tick.
        self.dirty = False
        self.ready = None
        if built is None:
            # Keep suppressing any older revision still awaiting app-idle approval.
            status('Build failed · request barrier retained until correction or revert')
            return
        if publish_artifact(built) is None:
            status('Build publication failed · request barrier retained; no reload')
            return
        # Keep the request barrier up until both artifact and revision are published.
        atomic_write(self.revision, str(time.time_ns()))
        self.applied = current
        self.request.unlink(missing_ok=True)
        status("Reload requested · Pi Mac rechecks that all sessions are idle")


def running_apps(binary):
    """Find other instances of this project's executable, not unrelated Pi Mac installs."""
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,command="], text=True, errors="replace"
    )
    executable = str(binary.resolve())
    build_root = str(root / ".build") + "/"
    result = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2:
            continue
        command = fields[1]
        # Bundle paths contain spaces. Also catch the old bare debug executable
        # when upgrading a watcher, so it cannot run alongside the new app.
        exact = command == executable or command.startswith(executable + " ")
        old_debug = command.startswith(build_root) and (
            command.endswith("/PiMac") or "/PiMac " in command)
        if exact or old_debug:
            result.append(int(fields[0]))
    return result


def run_build_command(command, capture=False):
    # Isolate build descendants from the app and terminal process group. Python
    # owns cancellation, including npm/node grandchildren that inherit SIGINT.
    process = subprocess.Popen(
        command, start_new_session=True, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE if capture else subprocess.STDOUT,
        text=True, errors="replace",
    )
    try:
        output, errors = process.communicate()
        if errors:
            print(errors, end="", file=sys.stderr, flush=True)
        if not capture:
            build_log.parent.mkdir(parents=True, exist_ok=True)
            with build_log.open("a") as log:
                log.write(f"\n$ {' '.join(command)}\n{output}")
            if verbose:
                print(output, end="", flush=True)
            elif process.returncode != 0:
                # Keep terminal diagnostics bounded; the complete output is on disk.
                print("\n".join(output.splitlines()[-40:]), file=sys.stderr, flush=True)
        return process.returncode, output
    except BaseException:
        # Do not wait indefinitely for a build tool's shutdown handler.
        try:
            os.killpg(process.pid, signal.SIGTERM)
            process.wait(timeout=2)
        except (ProcessLookupError, subprocess.TimeoutExpired):
            pass
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        raise


def build():
    global build_number
    build_number += 1
    started = time.monotonic()
    build_log.parent.mkdir(parents=True, exist_ok=True)
    build_log.write_text(f"Build #{build_number} — {time.strftime('%Y-%m-%d %H:%M:%S')}\n")
    status(f"Build #{build_number} · Server → Swift…")
    # Bundle the backend before Swift copies resources. Never signal a reload
    # when either build fails, even if an old executable still exists.
    if run_build_command(["npm", "--prefix", "sidecars/t3-server", "run", "build"])[0] != 0:
        status(f"Build #{build_number} failed (Server); no restart. Details: {build_log.relative_to(root)}")
        return None
    if run_build_command(["swift", "build"])[0] != 0:
        status(f"Build #{build_number} failed (Swift); no restart. Details: {build_log.relative_to(root)}")
        return None
    code, output = run_build_command(["swift", "build", "--show-bin-path"], capture=True)
    if code != 0:
        with build_log.open("a") as log:
            log.write(output)
        print(output, end="", file=sys.stderr, flush=True)
        status(f"Build #{build_number} failed (binary path); no restart.")
        return None
    # Build into a staging bundle: a build can become obsolete while compiling.
    # Never replace the running application's resources until PendingBuild validates it.
    binary = bundle_development_app(Path(output.strip()), root / '.build' / 'Pi Mac Dev Staged.app')
    if binary is None:
        status(f"Build #{build_number} failed (development app); no restart. Details: {build_log.relative_to(root)}")
        return None
    status(f"Build #{build_number} ready · {time.monotonic() - started:.1f}s")
    return binary


def publish_artifact(binary):
    staged = root / '.build' / 'Pi Mac Dev Staged.app'
    if binary != staged / 'Contents' / 'MacOS' / 'PiMac':
        return binary  # Supports prebuilt binaries and transport fixtures.
    live = root / '.build' / 'Pi Mac Dev.app'
    previous = root / '.build' / 'Pi Mac Dev Previous.app'
    if previous.exists():
        shutil.rmtree(previous)
    try:
        if live.exists():
            live.rename(previous)
        staged.rename(live)
        register = Path('/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister')
        if run_build_command([str(register), '-f', str(live)])[0] != 0:
            live.rename(staged)
            if previous.exists():
                previous.rename(live)
            status('Cannot register published app · restored previous bundle')
            return None
    except OSError as error:
        if previous.exists() and not live.exists():
            previous.rename(live)
        status(f'Cannot publish staged app: {error}')
        return None
    return live / 'Contents' / 'MacOS' / 'PiMac'


def bundle_development_app(binary_dir, destination=None):
    """Give debug builds a real application identity for macOS notifications.

    Keep the executable path stable for DevelopmentReloader; replace the file
    atomically so an already running process keeps its original executable.
    The dev identity is separate from the release app's permissions/defaults.
    """
    app = destination or root / ".build" / "Pi Mac Dev.app"
    contents = app / "Contents"
    macos = contents / "MacOS"
    resources = contents / "Resources"
    macos.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    binary = macos / "PiMac"
    staged = macos / "PiMac.next"
    shutil.copy2(binary_dir / "PiMac", staged)
    staged.replace(binary)
    resource_bundle = resources / "PiMac_PiMacApp.bundle"
    if resource_bundle.exists():
        shutil.rmtree(resource_bundle)
    shutil.copytree(binary_dir / "PiMac_PiMacApp.bundle", resource_bundle)
    shutil.copy2(root / "Sources/PiMacApp/Resources/AppIcon.icns", resources / "AppIcon.icns")
    with (contents / "Info.plist").open("wb") as plist:
        plistlib.dump({
            "CFBundleDisplayName": "Pi Mac Dev",
            "CFBundleExecutable": "PiMac",
            "CFBundleIdentifier": "com.jianfeng.pi-mac.dev",
            "CFBundleIconFile": "AppIcon",
            "CFBundleName": "Pi Mac Dev",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "NSHighResolutionCapable": True,
            "NSAppleEventsUsageDescription": "Request system administrator authorization for temporary network and power settings.",
            "NSAppTransportSecurity": {"NSAllowsLocalNetworking": True},
        }, plist)
    if run_build_command(["codesign", "--force", "--deep", "--sign",
                          os.environ.get("CODE_SIGN_IDENTITY", "-"), str(app)])[0] != 0:
        return None
    register = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
    if destination is None and run_build_command([str(register), "-f", str(app)])[0] != 0:
        return None
    return binary


def process_table():
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,ppid=,pgid=,command="], text=True, errors="replace")
    result = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            result[int(fields[0])] = (int(fields[1]), int(fields[2]), fields[3])
    return result


def owned_processes(table, app_groups):
    owned = set()
    build_root = str(root / ".build") + "/"
    for pid, (_, group, command) in table.items():
        # Match executable/entry paths, not arbitrary mentions of PiMac (editors,
        # terminals or unrelated Pi CLI sessions). Include prior orphan gateways.
        app = command.startswith(build_root) and (
            command.endswith("/PiMac") or "/PiMac " in command)
        executable, _, arguments = command.partition(" ")
        gateway = Path(executable).name == "node" and (
            arguments.startswith(str(root) + "/")
            and arguments.endswith("/t3-bridge/server-gateway.mjs"))
        if app or gateway or group in app_groups:
            owned.add(pid)
    while True:
        descendants = {pid for pid, (parent, _, _) in table.items() if parent in owned}
        if descendants <= owned:
            return owned - {os.getpid()}
        owned.update(descendants)


def cleanup(app_groups):
    status("Stopping Pi Mac and its services…")
    # Capture descendants before parents exit/reparent them. Rescan during the
    # grace period to catch a concurrent hot relaunch, then force stragglers out.
    tracked = {}
    deadline = time.monotonic() + 3
    while True:
        for pid in tracked:
            try:
                os.waitpid(pid, os.WNOHANG)
            except ChildProcessError:
                pass
        table = process_table()
        targets = owned_processes(table, app_groups)
        for pid in targets:
            tracked.setdefault(pid, table[pid][2])
        alive = {pid for pid, command in tracked.items()
                 if pid in table and table[pid][2] == command}
        if not alive:
            return
        force = time.monotonic() >= deadline
        for pid in alive:
            try:
                os.kill(pid, signal.SIGKILL if force else signal.SIGTERM)
            except ProcessLookupError:
                pass
        if force:
            for pid in alive:
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass
            return
        time.sleep(0.1)


def main():
    # Keep the lock descriptor open for the watcher's lifetime. An OS lock is released even
    # after a crash, unlike a PID file left behind by an interrupted watcher.
    key = hashlib.sha256(str(root).encode()).hexdigest()[:16]
    lock_path = Path(tempfile.gettempdir()) / f"pimac-dev-{key}.lock"
    with lock_path.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit("A Pi Mac dev watcher is already running for this project.")

        app_groups = set()
        try:
            watch(app_groups)
        finally:
            # A second Ctrl-C must not interrupt cleanup and leave services behind.
            handlers = {sig: signal.signal(sig, signal.SIG_IGN)
                        for sig in (signal.SIGINT, signal.SIGTERM)}
            try:
                cleanup(app_groups)
            finally:
                for sig, handler in handlers.items():
                    signal.signal(sig, handler)


def watch(app_groups):
    binary = build()
    if binary is None:
        sys.exit(1)
    live_binary = root / '.build' / 'Pi Mac Dev.app' / 'Contents' / 'MacOS' / 'PiMac'
    existing = running_apps(live_binary)
    if existing:
        sys.exit(
            f"Pi Mac is already running (PID {', '.join(map(str, existing))}). "
            "Stopping this project's instances and services on exit; "
            "run the watcher again after cleanup."
        )
    binary = publish_artifact(binary)
    if binary is None:
        sys.exit(1)
    env = os.environ.copy()
    env["PIMAC_DEV_EDIT_DIRECTORY"] = str(edit_directory())
    env["PIMAC_DEV_RELOAD_PATH"] = str(binary.resolve())
    revision = root / ".build" / "pimac-dev-revision"
    revision.write_text(str(time.time_ns()))
    env["PIMAC_DEV_RELOAD_REVISION"] = str(revision)
    state = root / ".build" / "pimac-dev-state.json"
    request = root / ".build" / "pimac-dev-request"
    state.unlink(missing_ok=True)
    request.unlink(missing_ok=True)
    env["PIMAC_DEV_STATE_PATH"] = str(state)
    env["PIMAC_DEV_REQUEST_PATH"] = str(request)
    restart = root / ".build" / "pimac-dev-restart.json"
    env["PIMAC_DEV_RESTART_PATH"] = str(restart)
    supervisor = AppSupervisor(binary, env, state, restart, app_groups)
    supervisor.launch()
    status("Watching Swift, Server, extensions and resources · Ctrl-C to stop")
    if verbose:
        status(f"Build log: {build_log.relative_to(root)} · App logs: terminal")
    else:
        status(f"Logs: {build_log.relative_to(root)} (latest build), {app_log.relative_to(root)} (app), .build/dev-watch.log (lifecycle)")
    pending = PendingBuild(snapshot(), request, revision, supervisor.app.pid)
    while True:
        time.sleep(1)
        supervisor.tick()
        pending.expected_pid = supervisor.app.pid
        pending.tick(state)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="show build output and live app logs in the terminal")
    controls = parser.add_mutually_exclusive_group()
    controls.add_argument('--begin-edit', action='store_true', help='begin an explicit edit batch; print its token')
    controls.add_argument('--end-edit', metavar='TOKEN', help='complete only the named edit batch')
    controls.add_argument('--status', action='store_true', help='show unfinished edit batches without launching/stopping the app')
    parser.add_argument('--label', default='coding work', help='label for --begin-edit')
    arguments = parser.parse_args()
    verbose = arguments.verbose
    if arguments.begin_edit:
        print(begin_edit(arguments.label))
        sys.exit(0)
    if arguments.end_edit:
        try:
            end_edit(arguments.end_edit)
        except ValueError as error:
            sys.exit(str(error))
        sys.exit(0)
    if arguments.status:
        print(json.dumps([read_state(edit_directory() / (token + '.json')) for token in edit_blockers()], ensure_ascii=False))
        sys.exit(0)
    # Explicitly restore Ctrl-C even if the invoking environment ignored SIGINT.
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except KeyboardInterrupt:
        status("Stopped · Pi Mac and its services have been stopped")
        sys.exit(130)
    except RuntimeError as error:
        status(f"Stopped · {error}")
        sys.exit(1)
