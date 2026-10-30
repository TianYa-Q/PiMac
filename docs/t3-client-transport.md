# Native T3 client transport

Reference the same pinned official v0.1.3 revision as the Server:
`d2c440312e5f39d59827ed466838a623516454d6`. Electron vs Swift changes the UI
and platform APIs, not the server protocol or connection lifetime.

Official source references:

- `apps/desktop/src/backend/DesktopLocalEnvironmentAuth.ts`: shared bearer
  acquisition, credential reuse and bounded transient-bootstrap retry.
- `packages/client-runtime/src/rpc/session.ts`: session-scoped socket/protocol,
  initial configuration from `subscribeServerConfig`, then live updates.
- `packages/client-runtime/src/rpc/protocol.ts` and Effect `RpcMessage.ts`:
  request IDs, chunk ACK, request interruption and 15-second ping timeout.
- `apps/server/src/ws.ts`: authoritative configuration stream event shapes.

## Swift mapping

`T3RPCSession.swift` owns one connection per environment, a single receive loop,
request-ID multiplexing and keepalive. Concurrent first requests share ticket
acquisition. Every waiting request can cancel independently, including while
connecting. Stream subscriptions have an initial-response timeout; after their
first chunk, the connection heartbeat monitors liveness. Per-request cancellation
or timeout sends `Interrupt`, not a socket close. A transport failure fails all
pending requests, without retrying/replaying any command. A later request can
establish a fresh connection. Shutdown/environment change invalidates the old
connection and discards late results.

`T3DesktopClient.swift` observes `subscribeServerConfig` snapshots and incremental
settings/provider events. Official configuration availability does not wait for
writing a desktop model preference or refreshing extra native model metadata.
The subscription retries after transport failure and takes a fresh snapshot.
No local default model preference means no write, not clearing the Server's
selection. Identical local/Server selections do not cause an update. Explicit
model-list refresh remains available; routine startup does not poll `getConfig`
or `getSettings`.

The supervisor's private credential issuance is a deliberate host integration
rather than Electron's bootstrap channel. Public authentication, scopes and
command readiness remain upstream-owned. Thread polling and media transport are
separate concerns and are not replaced by this change.

## Session readiness and Stop

Opening an existing session validates its project against the authenticated live
shell already acquired by `waitUntilReady`; it does not call `ensureProject` or
wait for another complete shell read. Cached transcript display and background
thread/media hydration do not authorize commands, but also do not block sending
once live configuration and shell identity are available.

A fresh outbox message for a known existing thread binds to that live environment
without downloading the transcript first. A bound/uncertain delivery still uses
the recovery inspection and frozen command ID; this optimization does not replay
unknown commands under a new identity. Recovery reuses the live configuration's
environment ID rather than repeatedly invoking `server.getConfig`.

Official reference: `packages/client-runtime/src/operations/commands.ts`,
`interruptThreadTurn` and `cancelQueuedRun`. Stop prefers the advertised
`threadStop` capability and dispatches `thread.stop` without a cached run ID.
Older servers fall back to `run.interrupt` with `holdQueue: true`. The client
cancels its local preparation/backoff before Stop, with cancellation checks after
uploads and before mutations; Stop never waits for that delivery's receipt.
Already transmitted outcomes remain recoverable/unknown, not falsely withdrawn.

Thread refresh scheduling starts independently of shell refreshes. Queue cancel
and Stop acknowledgements therefore trigger thread status reads even while a
full shell read is slow. Preparing/cached-running sessions retain the Stop
control before the first run detail arrives; duplicate Stop/cancel clicks are
disabled while awaiting acknowledgment. Idle sessions reserve the control's
space to avoid layout movement.

Queued cancellation is an official `queued-run.cancel` command, not deleting local
history. The pencil action is explicitly **cancel and retrieve draft**, not the
official in-place `queued-run.edit` editor. Draft restoration requires a successful
cancellation and never overwrites newly typed input. If a run started meanwhile,
the Server rejects cancellation and the client reports the uncertainty. Neither
cancelling a queue item nor stopping a run reverses effects already executed.

## Regression coverage

`T3RPCSessionTests` checks concurrent/reversed/batched responses, stream ACK,
request-local cancellation/timeouts, failure isolation, pending-connect
cancellation, stale results and no mutation replay. Its isolated real Server test
asserts one ticket/socket for startup + configuration subscription + 20 concurrent
reads, live settings changes from a second client, and resubscription after a real
Server restart. It also asserts no startup `server.updateSettings` or
`server.getConfig` for an absent local preference.

`MessageRecoveryTests` checks the fresh live send shortcut, unknown-outcome
inspection with identical frozen commands, and cancellation during a suspended
upload (no late dispatch). `MessageRecoveryIntegrationTests` holds a delivery
preflight open while a real isolated Server cancels a queued run and stops the
active Pi fixture, verifies the remaining queue is held, then releases preflight
and checks that the cancelled submission never reaches the Server. Disk shell
cache alone cannot enable the live shortcut (`T3DesktopTests`).

Use single-worker Swift tests (`--jobs 1 --no-parallel`), plus `T3DesktopTests`,
`T3ConnectionRecoveryTests`, `T3LifecycleTests` and affected feature suites.
Fixture measurements do not establish real-state startup/UI timings; accept
those only after a safe updated-app reload.
