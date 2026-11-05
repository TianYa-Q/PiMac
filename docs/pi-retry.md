# Pi persistent transient-error recovery

## Ownership and policy

Pi owns recovery for ordinary chats and Goals alike. We reuse Pi 1.3.0's existing
agent retry loop, failed-response projection, timers, abort controllers and RPC
progress events. No client retry loop, synthetic user “continue” message or new
Goal is introduced. Successful tool executions are not replayed.

The personal configuration installed by `scripts/install-pi-retry.ts` is:

```json
{
  "retry": {
    "enabled": true,
    "unlimited": true,
    "baseDelayMs": 2000,
    "maxAgentDelayMs": 60000
  }
}
```

- Transient transport failures, temporary throttling and upstream outages retry
  until success or user cancellation: 2, 4, 8, 16, 32, 60 seconds, then 60 seconds.
- Auth/permission/invalid-request errors and quota/billing exhaustion take
  precedence over transient wording and terminate immediately. Existing account
  quota-switching behavior remains separate and unchanged.
- Success resets Pi's counter. Stop interrupts both active requests and backoff.
- Compaction and branch summaries use the same resolved retry budget.
- `unlimited: false` restores the configured finite `maxRetries` policy; an
  explicit `maxRetries: 0` still means no retries, not infinity. Project settings
  can override personal settings. Disabling `retry.enabled` still works.
- Provider-internal retries are not increased. Continuous recovery may consume
  provider usage, including partial responses; it is not exactly-once remote
  request delivery and cannot survive process termination or a machine restart.

The patch resolves `retry.unlimited: true` to in-memory `Infinity`, not an enormous
finite number. JSON RPC represents that budget as `null`; a narrow Pi Adapter
patch preserves it in the official nullable `maxAttempts` contract. Attempts and
backoff remain visible through existing Server/native retry presentation.

The unmodified `@schovest/pi-goal` owns Goal-specific settled-boundary recovery.
Pi retries remain primary. The previous `pi-goal-x` classifier/scheduler patches
are no longer installed; its exact fallback classification is not promised for
the replacement package. Stop/pause during backoff is verified through the real
new Goal extension and Pi RPC.

## Install and check

Use the exact package directory belonging to the Pi executable configured in
PiMac; do not substitute another installation:

```sh
sidecars/t3-server/node_modules/.bin/tsx scripts/install-pi-retry.ts --package-root /path/to/pi-coding-agent
sidecars/t3-server/node_modules/.bin/tsx scripts/install-pi-retry.ts --package-root /path/to/pi-coding-agent --check
sidecars/t3-server/node_modules/.bin/tsx scripts/install-pi-goal.ts
```

The installer supports only the pinned Pi and pi-ai 1.3.0 distributions. It verifies
all four complete source hashes and unique anchors before changing code, updates
both SDK and bundled CLI/RPC implementations, and uses Pi's settings-storage lock
to merge only retry settings. Unknown versions or source modifications are errors.
Reinstalling/upgrading Pi can remove patches: revalidate before claiming persistent
recovery is enabled. Remove the patches when upstream provides an equivalent
unlimited budget, permanent-error precedence and nullable RPC reporting contract.

No installer restarts running processes. Existing processes retain their loaded
code/settings until a normal new process; closing a client tab alone is not a
promise that the Server replaces its Pi process. Server Adapter changes also need
the normal build/reload gates; a Pi retry event with a null budget on an older
Server remains functional, but may show an incorrect finite total until updated.

## Verification

```sh
PI_RETRY_PACKAGE_ROOT=/path/to/pi-coding-agent \
PI_RETRY_GOAL_ROOT=/path/to/PiMac/extensions/pi-goal \
sidecars/t3-server/node_modules/.bin/tsx scripts/test-pi-retry.ts
```

This uses the actual installed SDK and bundled Pi RPC, a deterministic offline
Provider, a temporary agent directory and the real Goal extension. It verifies
seven transient failures then success, omitted failed responses in model context,
one observable tool side effect, permanent errors, active Goal state during retry,
immediate stop during backoff, and no post-stop restart. The replacement module
can report `blocked` after aborting a failed request rather than `paused`; both
are stopped states, and this upstream difference is not patched. It makes no remote model calls
and reads no user credentials. Artifacts stay under `tmp/pi-retry-*`.

Focused Node tests cover the Goal presentation adapter and Server nullable
budget projection. These tests do not constitute real-provider outage acceptance
or release of the running Server/native app.
