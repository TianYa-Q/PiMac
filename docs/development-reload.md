# Development reload safety

`python3 scripts/dev.py` automatically builds and reloads **runtime** changes. It no longer treats a pause between file saves as proof that a coding task is complete.

## Decision gates

- SHA-256 content fingerprints, not mtimes: an identical save does nothing. Reverting all pending changes to the applied contents cancels the reload.
- Watch `Package.swift`, `Sources`, runtime server files and extensions. Tests, docs, the watcher itself, dependencies and generated/vendor directories do not independently trigger a reload.
- Require a fresh `watching`-phase idle heartbeat belonging to the **current supervised app PID**. Existing desktop/Telegram queues, unconfirmed operations, Git, authorization and running server tasks remain blockers.
- External project Swift builds/tests and `node --test` executions block a build/reload. Unrelated projects and old orphaned XCTest processes do not.
- An unfinished explicit edit batch blocks reload indefinitely; it never expires just because the editor or coding agent went quiet. The app independently checks this barrier immediately before draining services.
- Build into `Pi Mac Dev Staged.app`, leaving the live bundle untouched. Recheck content, work barriers and heartbeat after building; publish the validated bundle and revision before releasing the request barrier. If work began during the build but contents did not change, reuse the ready artifact rather than rebuilding it repeatedly.
- Registration failure restores the previous bundle. Build failure does not signal a reload. Existing shutdown/reap/startup barriers are retained.

## Coding batches (agents and multi-step edits)

Process/heartbeat checks cannot know whether a quiet editor or a temporarily idle conversation has finished a whole implementation. Use an explicit batch around multi-step coding work:

```sh
TOKEN=$(python3 scripts/dev.py --begin-edit --label 'image delivery')
# Edit runtime code, run checks, inspect results, and resolve failures.
python3 scripts/dev.py --end-edit "$TOKEN"
```

These control commands do not launch, stop or restart the app. Ending a batch permits automatic reload only when **all** other batches and safety gates are clear. Concurrent workers each use their own token; completing one cannot release another. After an interrupted task, inspect `python3 scripts/dev.py --status` and explicitly complete the relevant token when it is safe. Do not expire or delete other workers' tokens automatically.

## Updating the watcher

An already running Python process still uses its loaded old code. Updating `scripts/dev.py` alone deliberately does not trigger an app rebuild. After all work is idle, stop the old watcher and start the new watcher once. Ctrl-C stops its app/services, so do not do this during active tasks.

Tests: `python3 -m unittest discover -s Tests/DevWatcher -v`, plus Swift `DevelopmentReloadStateTests`.
