# T3 Code iOS integration

Desktop, Telegram and the unmodified T3 iOS client now use one native T3 Server:

```text
SwiftUI / Telegram / protocol-2 iOS → official T3 orchestrator V2 → official Pi Provider → Pi runtime
```

There is no desktop-state projection, private workspace command bridge or second
session-file writer. See [architecture and limitations](t3-server-migration.md).
The pinned upstream revision is recorded in `sidecars/t3-server/upstream-pin.json`.
Protocol tests are not evidence that the installed App Store version interoperates.

## Phone connection

1. Build the new app; restart only after existing tasks finish.
2. Open **Settings → T3 iOS 连接** and authorize official T3 Connect using the
   same account as the App Store T3 iOS client.
3. On the phone, delete the old **Pi Mac · LAN** entry (if present), then enable
   **Pi Mac · Tunnel** under T3 Connect. No custom iOS build or patch is needed.
4. Keep Pi Mac awake and online. LAN listeners and pairing controls are removed;
   upgrade clears legacy saved LAN consent. The desktop Server stays on loopback.
5. Pausing publication only pauses activity updates; unlinking revokes the Tunnel.

The iOS catalog is keyed by `environmentId`. Registering Tunnel for a Server
already saved as LAN replaces that catalog entry; labels cannot make them two
independent environments. We intentionally offer only Tunnel rather than fake
an identity or run a second orchestration engine.

Cloudflare terminates HTTPS and forwards to the private loopback Server.
Same-origin WebSocket validation uses the forwarded HTTPS scheme, not a fixed
HTTP scheme; mismatched origins and invalid/replayed DPoP proofs remain denied.
Remote tasks have local Pi permissions, and transcripts/attachments pass through
Cloudflare. This is authenticated TLS transport, not end-to-end encryption.

## Connection diagnostics

Settings expose the latest 20 credential-free events. A bounded private log is
written to
`~/Library/Application Support/PiMac/T3/server-owned/connection-diagnostics.log`
with one rotated `.1` file (approximately 256 KiB each, mode 0600).
Events include route/method, transport, HTTP status, Origin rejection and DPoP
failure classification. Query strings, tickets, proofs, tokens, pairing codes,
request bodies and transcripts are never logged. Logs can identify whether
Tunnel traffic reaches the Server; absence of traffic is not proof of readiness.

## Native client behavior

The Server provides stock environment discovery, pairing, bearer sessions,
WebSocket tickets, configuration, shell/thread snapshots and subscriptions.
HTTP and RPC mutations go through the same native engine and durable receipts.
Projects, threads, revisions and continuation identity do not depend on desktop
tabs, selected projects or a desktop Pi process.

Supported operations include thread creation, text/image turns, model/thinking
selection, steering, cancellation, /compact and official extension runtime requests.
The desktop selects full-access/default mode; upstream Pi also supports tool
approval policies (these are not an OS sandbox). Images use official attachment
persistence and signed asset URLs. Desktop terminal/worktree/rollback controls
remain unavailable rather than falling back to a private Pi RPC.
Clients must support orchestration protocol 2; real App Store acceptance remains
pending. See docs/t3-server-migration.md for wire-output and upgrade limitations.
Command acceptance is not task completion; unknown outcomes must be inspected
before resubmitting. `agent_settled`, not `agent_end`, determines completion.

Pi output-speed telemetry is a narrow build-time adapter patch, not a separate
orchestration or persistence path. It aggregates provider-reported `usage.output`
from assistant messages into native `turnTokenUsage`, with an optional
`assistantDurationMs` wire field measured between assistant start/end events.
Tool time and requests without known output usage are excluded. The desktop can
show speed without context-window stats; new runs do not reuse old throughput.
Both server and desktop-client bundles must be rebuilt when this schema changes.

The desktop currently reads native HTTP snapshots by polling. iOS uses upstream
shell/thread subscriptions and completion markers. Pairing or socket connection
does not prove that the phone rendered the catalog. The retired desktop-bridge
counter endpoint is no longer available.

Old JSONL transcripts and legacy authorization/identity stores are not silently
imported or rebound. Existing phone installations should remove the old LAN entry and enable Tunnel. New
threads use the Server-owned database and private per-instance Pi sessions.

## T3 Connect notifications

Official hosted OAuth/PKCE binds the environment and starts a managed Tunnel;
the OAuth callback listens only on `127.0.0.1:34338`. Notifications publish
title/model/phase/timestamp/opaque-link metadata, not full prompts or attachments.
Titles can contain sensitive text. Credentials and signing material remain private.
A successful publish or device count does not prove phone delivery.

Real Apple login, APNs, Live Activities and installed App Store interoperability
still require physical-device acceptance. Local protocol tests simulate TLS
termination and authentication, not the hosted relay or real mobile device.

## Ownership and recovery

T3 Server is app-owned: it starts with Pi Mac, and Cmd-Q / closing the last
window waits for Server, Pi and Tunnel finalizers before the app exits. Closing
or changing a SwiftUI view alone does not stop the service. Development reload
uses the same shutdown barrier. A rapid relaunch waits up to 15 seconds for the
old child's kernel lock rather than stealing it. EOF requests shutdown; reparent detection also
stops Node after the app crashes, even if an inherited pipe keeps EOF delayed.

The supervisor holds `owner.lock` until Node exits. Node holds a BSD kernel
lock on `child-owner.lock` using macOS `lockf` descriptor mode. Locks release on
process exit, even SIGKILL; never unlink these lock files. `child-owner.json` is
only diagnostic metadata, not the lock or shutdown barrier. A proven-dead legacy
PID marker is archived during startup under the kernel lock; a live, malformed
or unsafe legacy marker remains denied. No live lock stealing, state reset,
history activation or uncertain prompt replay is performed.

A forced kill of Node itself cannot run provider finalizers; inspect surviving
sidecars before manual recovery. Never kill unrelated processes or remove live
locks/credential files.

## Build and verification

Requires Node.js 24+, npm, Git and Swift/macOS:

```sh
./scripts/prepare-t3-server.sh
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
swift test
./scripts/package-app.sh
```

The preparation step verifies 673 pinned upstream files and bundles the real
Server; it does not launch Pi or download anything at app startup. Native Server
integration tests use a protocol-only Pi fixture without real accounts/models.
The retired bridge tests are not part of the new verification chain.
