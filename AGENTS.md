# Development watcher safety

For multi-step implementation work in this checkout, open a development edit batch **before changing runtime files**:

```sh
python3 scripts/dev.py --begin-edit --label 'short task description'
```

Retain the returned token. Keep that batch open through edits, builds, tests and resolving findings. After the task is complete, close only your batch with `python3 scripts/dev.py --end-edit TOKEN`. These commands do not launch or stop the application. They provide a task-completion barrier for the development watcher; do not rely on pauses between tool calls.

Do not expire, delete or close another worker's batch. If interrupted, leave the batch held and report its token for deliberate recovery (`--status` lists batches). Do not restart the watcher or running application during active tasks; the existing Python watcher must be restarted once, when safe, to load changes to its own script.

See `docs/development-reload.md` for the build/publication and app-idle safety gates.
