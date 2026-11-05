# Pi Goal integration

PiMac uses the unmodified `@schovest/pi-goal@0.2.1` package. The official package
owns goal persistence, tools, confirmation, safety limits and automatic continuation.
`extensions/pi-goal/index.ts` is a PiMac-owned presentation adapter: it invokes
that factory once and observes public `appendEntry("goal-state", ...)` calls,
then publishes validated state through `setStatus("pimac-goal", JSON)`. It does
not patch third-party files or implement another Goal scheduler.

## Install and verify

```sh
node --import ./extensions/pi-goal/node_modules/tsx/dist/loader.mjs scripts/install-pi-goal.ts
node --import ./extensions/pi-goal/node_modules/tsx/dist/loader.mjs scripts/install-pi-goal.ts --check
```

On a fresh checkout first run `npm ci --ignore-scripts --legacy-peer-deps --prefix extensions/pi-goal`.
The installer selects `npm:@schovest/pi-goal@0.2.1` with its direct extension
resource disabled, plus the local PiMac adapter that loads the same pinned engine.
This prevents duplicate `/goal` registrations. It removes `pi-goal-x` from package
selection, not from npm's cache, and preserves unrelated settings. The switch does
not create backups or migrate old goals. Old `.pi/goals` files are not read by the
new engine, and remain untouched rather than being silently destroyed. Chat
history is unchanged. Existing processes load their extensions once and require
a normal safe restart/reload; installation alone does not update loaded code.

## Native controls

- Start: `/goal <objective>`; one goal per Pi session, immediately executable.
- Status: `/goal status`.
- Pause/resume: `/goal pause`, `/goal resume`.
- Edit: `/goal edit <complete objective>`; retains usage, leaves paused goals paused.
- Clear: `/goal clear`; immediate, no confirmation, and no unrelated-turn abort.

Objectives are limited to 4,000 UTF-16 code units, matching the package validator.
The previous multi-goal picker, drafting modes and independent-auditor settings
are not available and are not shown as dead controls. Native creation and editing
use independent forms and do not consume the composer draft or attachments.
Running pause uses the separate Server Stop request; parent Stop explicitly sets
`stopDelegatedTasks: false` so app-owned delegated children survive.

Package configuration lives in `~/.pi/agent/pi-goal.json`. Defaults are 25 automatic
responses per epoch and a three-run no-progress guard. No unlimited mode or
managed-run RPC is silently enabled. The package's terminal settings UI remains
its own; in RPC mode bare `/goal` reports status rather than opening terminal UI.
The native app does not claim to expose that terminal settings screen.

The status bridge reads authoritative saved transitions, not an inferred title or
parsed statusline. Invalid payloads retain the last known Goal and report an error;
explicit `goal: null` clears the projection. The existing Server adapter validates
and mirrors reports into official `providerThread.goal`. Only the active provider
thread is shown. No provider/model/permission capability filter is added.

## Validation

```sh
npm --prefix extensions/pi-goal run typecheck
npm --prefix extensions/pi-goal test
node --import ./sidecars/t3-server/node_modules/tsx/dist/loader.mjs --test --test-concurrency=1 sidecars/t3-server/tests/pi-goal-status.test.ts
swift test --jobs 1 --no-parallel --filter 'GoalCommandTests|GoalCreationTests|GoalMenuLayoutTests|ThreadGoalTests|GoalExpansionTests|T3GoalControlTests'
```

The adapter tests launch real Pi 1.3.0 RPC in an isolated directory with no credentials,
seed a Goal through public session entries, and exercise restore, pause, edit and
clear without a model or confirmation dialog. Source remains unmodified.
The package's raw TS has a known Pi 1.3 typing mismatch in its
`before_agent_start` handler (`prompt` is absent on Pi's custom-event union member).
The adapter typecheck uses a declaration of the package's public factory, not a
claim that its internal source typechecks against Pi 1.3. Ordinary prompt and
custom-message autonomous execution require separate real-model acceptance.
The real offline retry test also loads the replacement engine: retrying keeps
Goal active and abort prevents further continuation. An abort after a failed
provider response currently becomes `blocked`, not necessarily `paused`; this
upstream behavior is retained and disclosed. The offscreen creation-form captures
show invalid button compositing, so they are not accepted as real UI evidence.
Native tests cover command routing, draft preservation, validation and compact
entry layout. The parent-stop isolated Server test also verifies a child survives,
then uses default cascading Stop as a control.

[Pi persistent retries](pi-retry.md) remains responsible for ordinary transient
transport recovery. The new Goal extension uses its own original settled-boundary
handling; the old `pi-goal-x` source patch installer and classifier tests are removed.
