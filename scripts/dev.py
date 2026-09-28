#!/usr/bin/env python3
"""Build on source changes; Pi Mac relaunches the built binary once all sessions are idle."""
import fcntl
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time

root = Path(__file__).resolve().parent.parent
os.chdir(root)


def snapshot():
    paths = [root / "Package.swift"]
    for directory in ("Sources", "Tests"):
        paths.extend((root / directory).rglob("*.swift"))
    return tuple(sorted((str(path), path.stat().st_mtime_ns, path.stat().st_size) for path in paths))


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


def build():
    print("Building Pi Mac...", flush=True)
    if subprocess.call(["swift", "build"]) != 0:
        print("Build failed; keeping the current app running.", file=sys.stderr, flush=True)
        return None
    return Path(subprocess.check_output(["swift", "build", "--show-bin-path"], text=True).strip()) / "PiMac"


if __name__ == "__main__":
    # Keep the lock descriptor open for the watcher's lifetime. An OS lock is released even
    # after a crash, unlike a PID file left behind by an interrupted watcher.
    key = hashlib.sha256(str(root).encode()).hexdigest()[:16]
    lock_path = Path(tempfile.gettempdir()) / f"pimac-dev-{key}.lock"
    with lock_path.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit("A Pi Mac dev watcher is already running for this project.")

        binary = build()
        if binary is None:
            sys.exit(1)
        existing = running_apps(binary)
        if existing:
            sys.exit(
                f"Pi Mac is already running (PID {', '.join(map(str, existing))}). "
                "Quit existing instances before starting the dev watcher; "
                "sessions may still be busy, so they are not terminated automatically."
            )
        env = os.environ.copy()
        env["PIMAC_DEV_RELOAD_PATH"] = str(binary.resolve())
        app = subprocess.Popen([str(binary)], env=env)
        threading.Thread(target=app.wait, daemon=True).start()
        print(
            "Watching Swift sources; a successful build restarts Pi Mac when all sessions "
            "are idle. Ctrl-C stops watching.", flush=True
        )
        previous = snapshot()
        try:
            while True:
                time.sleep(1)
                current = snapshot()
                if current == previous:
                    continue
                # Debounce editor saves and builds; avoid starting another build mid-write.
                time.sleep(0.7)
                previous = snapshot()
                build()
        except KeyboardInterrupt:
            print("\nStopped watching (Pi Mac remains open).")
