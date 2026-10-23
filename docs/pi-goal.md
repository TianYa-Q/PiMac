# Pi Goal integration

PiMac uses `pi-goal-x@0.32.3` for Pi Provider goals. Goal files, focus, task tracking,
auditing and automatic continuation remain owned by that extension. This is not
T3's provider interaction mode and does not add an autonomous loop to PiMac.

## Install / verify

From the repository root, with the desired Pi executable on `PATH`:

```sh
sidecars/t3-server/node_modules/.bin/tsx scripts/install-pi-goal.ts
sidecars/t3-server/node_modules/.bin/tsx scripts/install-pi-goal.ts --check
```

The installer uses Pi's personal package installation (honoring
`PI_CODING_AGENT_DIR`) and pins the exact npm version. It applies two small,
SHA-256-verified presentation patches to the installed extension:

- Publish the focused in-memory goal through the supported RPC
  `setStatus("pimac-goal", JSON)` channel whenever its UI state changes.
- Publish an explicit empty/current snapshot at session startup. Deduplication
  includes the session ID so switching sessions cannot retain a stale goal.

The patches do not change extension tools, model selection, scheduling, storage,
auditing or permissions. Unknown versions and local source modifications fail
explicitly instead of being overwritten. A package reinstall may remove the
patches: rerun the installer and `--check` after changing extension installations.
Nothing here restarts an existing Pi process or the running app; existing sessions
load the extension on a later normal reconnect/new process. Rebuilding/publishing
the Server and native UI follows the ordinary development idle gates.

## Use

Click **Goal** at the right of the project row above the composer. It is available
without an existing goal. In the native dialog, enter an objective and use the
primary **讨论并确认** action (guided drafting) or explicitly choose **直接开始**.
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
- `/goal-pause`, `/goal-resume`: pause/resume.
- `/goal-clear`: archive after confirmation (not Codex's `/goal clear`).
- `/goal-settings`: auditor and continuation settings, including a finite
  `maxAutonomousRuns` allowance if desired. The upstream default is unlimited.

The native card above the composer shows objective, lifecycle, elapsed active
time and tokens. Pi controls send the extension's original commands only when the
thread is idle, without touching unsent composer text or attachments. During
execution, use the existing Stop control; the extension observes the user abort.
Details/settings/focus/archive dialogs use the existing T3 extension UI bridge.
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

- Focused Swift tests cover wire validation, active-provider isolation, clearing
  and disconnected views; existing V2 presentation tests cover regression paths.
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
- Real-model autonomous continuation/auditor acceptance is not established by
  these tests. Full-page offscreen native capture produced invalid compositing;
  component-level captures are separate evidence, not running-app acceptance.
  The button before/after comparison compiles the actual composer header source
  fragment with identical offline data, dimensions and theme. New dialog captures
  show empty, ready and busy states; the offscreen window is inactive, so native
  default-button coloring can differ from an active application window.
