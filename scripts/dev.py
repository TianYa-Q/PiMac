#!/usr/bin/env python3
"""Build on source changes; Pi Mac relaunches the built binary once all sessions are idle."""
import os
from pathlib import Path
import subprocess
import sys
import threading
import time

root = Path(__file__).resolve().parent.parent
os.chdir(root)


def snapshot():
    paths = [root / "Package.swift"]
    for directory in ("Sources", "Tests"):
        paths.extend((root / directory).rglob("*.swift"))
    return tuple(sorted((str(path), path.stat().st_mtime_ns, path.stat().st_size) for path in paths))


def build():
    print("Building Pi Mac...", flush=True)
    if subprocess.call(["swift", "build"]) != 0:
        print("Build failed; keeping the current app running.", file=sys.stderr, flush=True)
        return None
    return Path(subprocess.check_output(["swift", "build", "--show-bin-path"], text=True).strip()) / "PiMac"


if __name__ == "__main__":
    binary = build()
    if binary is None:
        sys.exit(1)
    env = os.environ.copy()
    env["PIMAC_DEV_RELOAD_PATH"] = str(binary.resolve())
    app = subprocess.Popen([str(binary)], env=env)
    threading.Thread(target=app.wait, daemon=True).start()  # Reap it before the replacement starts.
    print("Watching Swift sources; a successful build restarts Pi Mac when all sessions are idle. Ctrl-C stops watching.", flush=True)
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
