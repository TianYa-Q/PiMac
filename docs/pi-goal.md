# Pi Goal integration

PiMac uses `pi-goal-x@0.32.3` for Pi Provider goals. Goal files, focus, task tracking,
auditing and automatic continuation remain owned by that extension. This is not
T3's provider interaction mode and does not add an autonomous loop to PiMac.

Transient request recovery is primarily owned by [Pi persistent retries](pi-retry.md),
for ordinary chats and Goals alike; the Goal scheduler is only a terminal-failure fallback.

## Install / verify

From the repository root, with the desired Pi executable on `PATH`:

```sh
sidecars/t3-server/node_modules/.bin/tsx scripts/install-pi-goal.ts
sidecars/t3-server/node_modules/.bin/tsx scripts/install-pi-goal.ts --check
```

The installer uses Pi's personal package installation (honoring
`PI_CODING_AGENT_DIR`) and pins the exact npm version. It applies small,
SHA-256-verified status, session-interaction and transport-classification patches to the installed extension:

- Publish the focused in-memory goal through the supported RPC
  `setStatus("pimac-goal", JSON)` channel whenever its UI state changes.
- Publish an explicit empty/current snapshot at session startup. Deduplication
  includes the session ID so switching sessions cannot retain a stale goal.

- Do not open the goal picker on session reconnection, even with multiple open
  goals. Leave the session unfocused until the user explicitly chooses a goal
  through **选择已有目标…** / `/goal-focus`.
- RPC `/goal-clear` archives only the currently focused goal immediately, without
  confirmation or an unfocused-goal picker. The explicit command/button is the
  user authorization; terminal confirmation, archive history and stale-focus
  checks remain intact.
- Preserve paused state across session reconnections without asking to resume.
- Tell the model to handle ordinary messages and independent tasks normally while
  paused, without asking/reminding the user to resume. Messages and related
  discussion are not consent to resume; `/goal-resume` remains explicit.

- Recognize `fetch failed`, common socket disconnects and Node transport error
  codes as recoverable Goal network failures. Pi's own retries run first; after
  settlement the extension's existing recovery policy owns backoff and attempt
  limits. Shared permanent-error exclusions prevent retrying auth/invalid-request
  failures even when they include transient wording. Final `agent_settled.aborted`
  pauses the active Goal when the user stops during Pi backoff, without arming a
  Goal recovery timer; an already paused Goal is never resumed.

The patches do not change extension tools, model selection, autonomous scheduling,
storage, auditing or permissions; transport classification only routes these
failures into the existing scheduler. They remove the implicit session-resume goal
picker and resume confirmation; explicit focus/resume and stale-continuation
guards remain upstream. Unknown versions and local source modifications fail
explicitly instead of being overwritten. A package reinstall may remove the
patches: rerun the installer and `--check` after changing extension installations.
Nothing here restarts an existing Pi process or the running app; existing sessions
load the extension on a later normal reconnect/new process. Rebuilding/publishing
the Server and native UI follows the ordinary development idle gates.

## Use

Without a focused goal, open **目标** at the right of the project row above the
composer. Choose **新建目标…** or **选择已有目标…**; the latter uses `/goal-focus`
and never silently selects a goal. In the native creation dialog, enter an
objective and use the primary **讨论并确认** action (guided drafting) or explicitly
choose **直接开始**.
The first maps to `/goal`, the second to `/goal-direct`; no command typing is
required. Cancel submits nothing, and neither action consumes the chat draft or
its attachments. Empty input cannot start. Busy/disconnected sessions disable the
entry with a tooltip; if availability changes while the dialog is open, a reason
is shown and both start actions are disabled. Switching projects or threads closes
the dialog so an unfinished goal cannot move silently to another context.

The original extension commands remain available for keyboard users:

- `/goal <idea>`: discuss and confirm the objective/plan.
- `/goal-direct <objective>`: start immediately, skipping guided drafting.
- `/goal-status`, `/goal-list`, `/goal-focus`: inspect or switch goals.
- `/goal-tweak <change>`: discuss and confirm revisions to the focused goal.
- `/goal-pause`, `/goal-resume`: pause/resume.
- `/goal-clear`: immediately archive the focused goal in PiMac/RPC, without a
  confirmation dialog (not Codex's `/goal clear`). Terminal sessions retain
  their original confirmation.
- `/goal-settings`: auditor and continuation settings, including a finite
  `maxAutonomousRuns` allowance if desired. The upstream default is unlimited.

The **当前目标** card above the composer shows objective, lifecycle, elapsed
active time and tokens. **编辑目标** opens a native full-text editor prefilled with
the current objective; **讨论并确认修改** submits the replacement text through
`/goal-tweak`, not a direct file write or a new goal. Empty, unchanged, stale,
completed or non-Pi revisions cannot submit. Cancellation changes nothing.
Closing the form requires successful local outbox persistence; asynchronous
transport failure remains visible through the existing delivery recovery flow.

**暂停执行 / 继续执行** control the lifecycle separately from editing. The card's
management menu contains progress, switching, creation, advanced settings and
archive; the redundant composer-row entry is hidden for a focused Pi goal.
**运行与审核设置（高级）…** still opens the extension's original settings picker:
it configures execution/auditing, not objective content. The raw advanced picker
has not been replaced by a native settings implementation.

Idle Pi controls send the extension's original commands without touching unsent
composer text or attachments. **暂停执行** also remains available during execution:
it uses the existing independent Stop request (also holding the message queue),
not a queued `/goal-pause` prompt. The extension observes the user abort and owns
the persisted paused state; the desktop does not optimistically fake that state.
Stopping disables repeated pause clicks. Editing, resume and management still
require an idle session. Switching projects,
threads or tabs destroys the local form context. Busy transitions keep editor
input and fixed feedback space; they do not queue a control command. Details,
settings and focus dialogs use the existing T3 extension UI bridge. Archive
executes directly without opening a dialog. Parent Stop uses upstream
`thread.stop` with `stopDelegatedTasks: false`, preserving independently running
app-owned delegated tasks; stopping a child remains an explicit action.
The card does not yet reproduce the terminal's full task tree or auditor panel.

## State boundary

`pi-goal-status.ts` validates the versioned RPC payload. Explicit `goal: null`
means no focused goal; missing fields, corrupt JSON, unknown statuses and invalid
counters are errors, not empty states. Invalid reports retain the last known goal
and surface an upstream extension error rather than terminating a healthy Pi run.
A narrow Pi Adapter patch mirrors validated state into the official
`providerThread.goal`, which T3 persists/projects normally.
Startup events can precede thread registration, so the adapter retains only the
latest report for that native session, clearing the buffer on session switches.

The desktop reads only `activeProviderThreadId`, never another provider's old
goal. Codex/Claude goal snapshots can also be displayed; the Pi extension command
buttons are shown only when the active driver is Pi. No provider/model capability
is disabled or filtered by this integration.

## Validation and limitations

- RPC clear tests execute the hash-verified 0.32.3 command handler, covering
  direct archive, no focused goal, stale focus, unchanged terminal confirmation
  and idempotent installation. They do not replace real-extension disk archive acceptance.
- A native-client/isolated-Server regression keeps fixture parent and child runs
  active, stops the parent and verifies the child survives; the default Server
  stop is then used as a control and does stop that same child. No live model or
  user task is involved.
- Running-pause Swift tests cover connected active-Pi availability and an isolated
  real Server stop while message delivery is suspended, preserving the draft and
  holding the queue without enqueueing `/goal-pause`. This Server test uses a goal
  projection fixture; it does not establish real-extension pause persistence.
- Focused Swift tests cover wire validation, active-provider isolation, clearing
  and disconnected views; existing V2 presentation tests cover regression paths.
- Paused-conversation regression tests execute the actual patched session-start
  handler and request-context function from a hash-verified 0.32.3 source fixture
  (`tests/fixtures/pi-goal-events-0.32.3.txt`, upstream MIT license alongside it).
  They cover repeated reconnections without confirmation or implicit resume,
  unfocused sessions with multiple open goals without a picker or goal mutation,
  quiet paused instructions, stale-checkpoint precedence, idempotent installation
  and upgrading the earlier status-only bridge. They do not prove model compliance.
- Node tests execute the actual installed bridge snippet, including deduplication,
  empty states and session changes. Adapter patch execution tests cover early
  reports, stale turn snapshots, malformed reports and session-switch isolation;
  pristine upstream hashes and patch anchors remain checked by maintenance tests.
- An isolated real Pi 1.3.0 RPC smoke used the upstream test hook to create a goal
  without automatic execution, then exercised native pause and confirmed archive.
  Structured reports followed active → paused → empty, with no model invocation,
  user credentials, running Server or production database.
- Native-entry tests exercise the actual action boundary (both modes, cancel,
  empty/busy/rejected actions) and an isolated local Server protocol fixture.
  The latter confirms exact `/goal` and `/goal-direct` dispatch, no duplicate
  submission and no draft/attachment consumption, without a live model/account.
- Transport regression tests execute the hash-verified upstream classifier and
  `agent_end` / `agent_settled` handlers. They cover fetch/socket failures, recovery
  only after settlement, configured cap handling, quota/billing exclusions and
  user-stop/paused-goal precedence, including cancellation after `agent_end` while
  Pi is in backoff. The persistent-retry offline RPC test also loads the real Goal
  extension and checks active → paused with no restart. Neither simulates a real provider outage.
- Real-model autonomous continuation/auditor acceptance is not established by
  these tests. Full-page offscreen native capture produced invalid compositing;
  component-level captures are separate evidence, not running-app acceptance.
  The button before/after comparison compiles the actual composer header source
  fragment with identical offline data, dimensions and theme. New dialog captures
  show empty, ready and busy states; the offscreen window is inactive, so native
  default-button coloring can differ from an active application window.
