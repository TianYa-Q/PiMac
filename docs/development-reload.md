# Development reload safety

`python3 scripts/dev.py` automatically builds and reloads **runtime** changes. It no longer treats a pause between file saves as proof that a coding task is complete.

## Startup

- With a usable published `.build/Pi Mac Dev.app`, launch it immediately without running npm, Swift compilation, signing, packaging or a source scan first. Only the published bundle is reusable, never `Pi Mac Dev Staged.app`.
- A missing or structurally incomplete published bundle still requires an initial successful build and publication. This removes the build wait from warm startup, not the app/Server's own initialization time.
- Each new bundle carries the source fingerprints captured **before** its build, included before signing. After launch, the watcher compares these with current sources and queues changes through the existing edit/idle/reload gates. It never labels old code as current merely because a fresh watcher started.
- Older bundles without fingerprints (or with unreadable fingerprints) can launch, but require a safe update; the unknown source state is reported explicitly. Failed updates leave the usable published app running.
- Changes to this Python launcher take effect on its next safe restart; editing it does not replace the already running watcher.

## Decision gates

- SHA-256 content fingerprints, not mtimes: an identical save does nothing. Reverting all pending changes to the applied contents cancels the reload.
- Watch `Package.swift`, `Sources`, runtime server files and extensions. Tests, docs, the watcher itself, dependencies and generated/vendor directories do not independently trigger a reload.
- Require a fresh `watching`-phase idle heartbeat belonging to the **current supervised app PID**. Existing desktop/Telegram queues, unconfirmed operations, Git, authorization and running server tasks remain blockers.
- External project Swift builds/tests and `node --test` executions block a build/reload. Unrelated projects and old orphaned XCTest processes do not.
- An unfinished explicit edit batch blocks reload indefinitely; it never expires just because the editor or coding agent went quiet. The app independently checks this barrier immediately before draining services.
- Development builds reuse Server outputs when `.build/dev-server-build.json` matches both actual inputs and generated runtime contents. Swift-only edits do not run npm/esbuild again. Inputs cover sidecar source/build configuration, upstream pin and pinned files, npm lock/install identity, Node executable identity and platform/architecture; outputs cover the Server bundle, license, native-runtime manifest and native dependency files. Missing/corrupt cache or outputs trigger one build; failed builds or input edits during a build never certify the cache. This cache is local to `dev.py`; explicit release/check commands keep their existing validation.
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

The T3 native-runtime upgrade adds `scripts/sign-native-runtime.sh` to both release and development packaging. It signs nested native addons and executable helpers (including mode `0700`) before the outer bundle. An older watcher does not acquire this new staging step until that one safe restart; do not restart it automatically as part of an active coding task.

Tests: `python3 -m unittest discover -s Tests/DevWatcher -v`, plus Swift `DevelopmentReloadStateTests`.
