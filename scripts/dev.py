#!/usr/bin/env python3
"""Coalesce source changes; build when Pi Mac is idle, then safely relaunch."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import signal
import sys
import tempfile
import time

root = Path(__file__).resolve().parent.parent
os.chdir(root)

verbose = False
build_log = root / ".build" / "dev-build.log"
app_log = root / ".build" / "dev-app.log"
build_number = 0


def status(message):
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


def changed_files(previous, current):
    before = {path: (mtime, size) for path, mtime, size in previous}
    after = {path: (mtime, size) for path, mtime, size in current}
    return sorted(Path(path).relative_to(root).as_posix()
                  for path in before.keys() | after.keys()
                  if before.get(path) != after.get(path))


def snapshot():
    paths = [root / "Package.swift"]
    excluded = {"node_modules", "upstream", "generated", "vendor", "__pycache__"}
    for directory in ("Sources", "Tests", "sidecars/t3-server", "extensions", "scripts"):
        # Prune before descending, not after rglob has traversed dependencies.
        for base, directories, files in os.walk(root / directory):
            directories[:] = [name for name in directories if name not in excluded]
            for name in files:
                path = Path(base) / name
                if path.suffix in {".swift", ".mjs", ".js", ".ts", ".json", ".py", ".sh", ".png"}:
                    paths.append(path)
    result = []
    for path in set(paths):
        try:
            stat = path.stat()
            result.append((str(path), stat.st_mtime_ns, stat.st_size))
        except FileNotFoundError:
            pass  # An editor can replace a file during a scan.
    return tuple(sorted(result))


def app_is_idle(state):
    """Fail closed if the app heartbeat is missing, stale, or malformed."""
    try:
        data = json.loads(state.read_text())
        age = time.time() - data["timestamp"]
        return data["idle"] is True and 0 <= age <= 3
    except (OSError, ValueError, KeyError, TypeError):
        return False


class PendingBuild:
    def __init__(self, previous, request, revision):
        self.previous = previous
        self.request = request
        self.revision = revision
        self.dirty = False
        self.changed_at = 0

    def observe(self, current):
        if current == self.previous:
            return
        changes = changed_files(self.previous, current)
        self.previous = current
        self.dirty = True
        self.changed_at = time.monotonic()
        self.request.write_text(str(time.time_ns()))
        preview = ", ".join(changes[:3])
        if len(changes) > 3:
            preview += f" (+{len(changes) - 3} more)"
        status(f"Changed · {preview} · waiting for idle before building")

    def tick(self, state):
        self.observe(snapshot())
        if not self.dirty or time.monotonic() - self.changed_at < 0.7 or not app_is_idle(state):
            return
        built = build()
        current = snapshot()
        if current != self.previous:
            self.observe(current)
            status("Sources changed during build · defer reload and build again when idle")
            return
        # A failed build is retried only after another edit, not every idle tick.
        self.dirty = False
        self.request.unlink(missing_ok=True)
        if built is not None:
            self.revision.write_text(str(time.time_ns()))
            status("Reload requested · Pi Mac rechecks that all sessions are idle")


def running_apps(binary):
    """Find other instances of this project's executable, not unrelated Pi Mac installs."""
    output = subprocess.check_output(
        ["ps", "-axo", "pid=,command="], text=True, errors="replace"
    )
    executable = str(binary.resolve())
    result = []
    for line in output.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and fields[1].split(" ", 1)[0] == executable:
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
    status(f"Build #{build_number} ready · {time.monotonic() - started:.1f}s")
    return Path(output.strip()) / "PiMac"


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
    existing = running_apps(binary)
    if existing:
        sys.exit(
            f"Pi Mac is already running (PID {', '.join(map(str, existing))}). "
            "Stopping this project's instances and services on exit; "
            "run the watcher again after cleanup."
        )
    env = os.environ.copy()
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
    # Isolate the app tree so shutdown can also collect orphaned services.
    app_log.parent.mkdir(parents=True, exist_ok=True)
    with app_log.open("w") as log:
        app = subprocess.Popen(
            [str(binary)], env=env, start_new_session=True, stdin=subprocess.DEVNULL,
            stdout=None if verbose else log, stderr=None if verbose else subprocess.STDOUT)
    # SIGINT can also arrive during startup/build/snapshot (handled by main).
    app_groups.add(app.pid)
    app.poll()
    status(f"Pi Mac started · PID {app.pid}")
    status("Watching Swift, Server, extensions and resources · Ctrl-C to stop")
    if verbose:
        status(f"Build log: {build_log.relative_to(root)} · App logs: terminal")
    else:
        status(f"Logs: {build_log.relative_to(root)} (latest build), {app_log.relative_to(root)} (app)")
    pending = PendingBuild(snapshot(), request, revision)
    while True:
        time.sleep(1)
        app.poll()  # Reap the initial app if it has relaunched itself.
        pending.tick(state)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("-v", "--verbose", action="store_true",
                        help="show build output and live app logs in the terminal")
    verbose = parser.parse_args().verbose
    # Explicitly restore Ctrl-C even if the invoking environment ignored SIGINT.
    signal.signal(signal.SIGINT, signal.default_int_handler)
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        main()
    except KeyboardInterrupt:
        status("Stopped · Pi Mac and its services have been stopped")
        sys.exit(130)
