# T3 Code iOS integration

Goal: the **unmodified App Store T3 Code iOS client** operates the sessions owned
by Pi Mac, synchronized with desktop and Telegram. No Pi extension, independent
agent, second session-file writer, or arbitrary-path session activation.

**Current scope: pairing, client initialization, bounded historical/live snapshots,
subscriptions, and opt-in text/inline-image sending to existing sessions.
Cancelling tasks, creating sessions, arbitrary file uploads, terminal/review,
provider management and T3 Connect are NOT implemented. Actual
App Store/iPhone compatibility has not been verified.** The audited source is a
protocol baseline, not evidence about the installed App Store version.

## Try the phone connection

Use a newly built Pi Mac; an already-running older binary does not gain new UI.
The development watcher restarts only when desktop/TG sessions are safe to stop.
Do not forcibly restart an app with running or queued tasks.

1. Open **Settings → T3 iOS 连接**, above Telegram settings.
2. Enable **允许手机访问（可信局域网 IPv4）**. Select a current local
   RFC1918 private IP; default port is 3773.
3. Click **启动连接** and confirm the network disclosure. The actual listening
   address appears only after startup succeeds. Invalid/nonlocal IPs and occupied
   ports fail rather than silently choosing another endpoint.
4. Click **生成一次性配对码**. In T3 iOS's Add Server screen, enter the displayed
   HTTP address and complete pairing code, or scan the QR **inside T3 iOS**. The
   code is an opaque 64-character credential, not a six-digit PIN. The pair URL
   keeps the credential in `#token=…`, never its query. Browser pairing is absent:
   opening this URL in Safari is not a supported sign-in flow.
5. Keep settings open until pairing completes. The unused grant is revoked on
   closing settings, replacing it, or clicking revoke; it expires after five
   minutes. QR/code disappear on expiry or consumption. Explicit copies of
   secrets are removed from the clipboard when the panel closes/code changes,
   only if the clipboard has not since been changed by another action.
6. Authorized devices appear in the same panel. **撤销授权** invalidates bearer
   credentials and outstanding tickets and terminates active sockets on both
   listeners. Stopping the service closes connections but does not revoke saved
   device authorization; bearer credentials otherwise expire after 30 days.

Networking is **off by default until explicitly confirmed**. After confirming
startup, Pi Mac saves the exact IP/port and automatically restores the connection
on subsequent launches, including after an unexpected service exit. App shutdown
and startup/listen failures do not clear consent. Clicking **停止连接** or unchecking
**允许手机访问** clears the saved preference and prevents automatic restoration.
If the saved IP is no longer local or its port is occupied, restoration fails
visibly rather than selecting another address; update the endpoint and start again.
Only endpoint/consent data is stored in defaults, never tokens or pairing codes.
No wildcard,
public-IP or DNS-name binding; only an explicitly selected local RFC1918
IPv4 address. CGNAT (`100.64.0.0/10`) addresses are rejected. UI discovery does not
prove phone reachability. The phone must reach that IP; check macOS
firewall/local-network permission.
IPv6, automatic Bonjour discovery, TLS and public tunnels are not implemented.

**Ordinary LAN HTTP is plaintext**, including bearer credentials and transcripts.
Use only a trusted local network and never add a
router port-forward. Do not share/screenshot pairing codes or include them in
bug reports. A separate public listener never serves `/internal/`, even with the
supervisor token. HTTP Origin-bearing requests are rejected; WebSocket upgrades
allow no Origin or this exact listening endpoint's Origin (for native iOS), not
an arbitrary origin or a client-supplied Host-derived allowlist. Cookies and DPoP
are unsupported and do not downgrade to bearer authentication.

## Diagnosing “Loading Threads”

Pairing and a connected WebSocket do **not** imply that the client has loaded its
shell snapshot. The pinned original mobile client first requests
`GET /api/orchestration/shell`, then resumes `orchestration.subscribeShell` using
that snapshot's sequence and `requestCompletionMarker: true`. If HTTP fails, it
requests a complete socket fallback snapshot. An empty catalog must also finish
with a `synchronized` marker.

Settings now show **列表链路诊断（本次服务累计）**, refreshed with the device list:

- No HTTP requests and no shell subscription: the client has not reached the
  list-read phase; inspect its initialization/connection state.
- HTTP 401/403: authorization/scope or Origin policy failed.
- HTTP 503 or catalog failures: the native catalog read/projection failed.
- HTTP 200 but no shell subscription: HTTP was served, but the client has not
  completed decoding/loading or reached socket resume.
- Shell snapshots and completion markers: the server generated the initial batch;
  this is **not** proof that the phone received, decoded or rendered it.
- `unsupported` RPC: the client requested something outside the reviewed subset.
  Do not enable arbitrary mutations or broaden authorization to work around it.

Counters and allowlisted RPC/failure names live only in memory and reset when
the service restarts. They are available solely through the admin-authenticated
loopback `GET /internal/auth/read-diagnostics`; the phone listener rejects it.
No request URLs, tickets, bearer tokens, paths, transcript text or raw errors are
retained. Counters are service-wide, not per-device, and the most recent failure
remains visible even after a later success.

A native binary-JSON regression was reproduced: Effect sets `ws.binaryType` to
`arraybuffer`, but the gateway's rate/JSON guard called `ArrayBuffer.toString()`
and closed a valid connection as invalid JSON. The guard now decodes bytes as
UTF-8. Both a binary-frame Node test and a real Swift URLSession HTTP-to-socket
resume/completion test fail without this fix and pass with it. This fixes an
observed transport defect; whether the installed App Store client hits this
specific defect still requires a physical iPhone test.

## Implemented architecture

### Private workspace bridge

Pi Mac supervises a bundled Node sidecar over anonymous stdin/stdout JSONL pipes.
`workspace.snapshot`, `session.prompt` and `session.abort` remain **local developer
diagnostics only** on an ephemeral loopback port with a separate 256-bit admin
token. Prompt/abort target an existing desktop runtime UUID; arbitrary paths do
not spawn/open another agent. These private mutations are not T3 RPC commands.
Generation checks discard stopped/replaced-child replies. Pipe writes run off the
main actor; stop has a bounded kill fallback. Sidecar stderr and Effect logging
are suppressed to avoid logging credentials or leaking payloads into JSONL.

### Authentication

- `/.well-known/t3/environment`, `/api/auth/session`, form-urlencoded `/oauth/token`,
  single-use `/api/auth/websocket-ticket`, pairing links and device revocation.
- Stable environment ID and device token **digests** are stored atomically under
  `~/Library/Application Support/PiMac/T3`; directory 0700, state files 0600.
- Pairing grants/tickets and connection counts are ephemeral. Tickets expire in
  30 seconds or at device expiry, whichever comes first.
- Mobile grants use upstream standard scopes because unmodified onboarding
  explicitly requests them. **A scope is not implemented feature support.**
  Admin scopes are excluded; only the desktop panel's private loopback authority
  can manage devices. Neither device nor admin credentials are saved in defaults.
- Corrupt/unsafe state fails closed. Failed durable auth commits disable live
  credentials and interrupt sockets instead of issuing ephemeral authorization.

### Mobile message sending

Enable **允许手机发送消息** in desktop T3 settings (off by default, separately
from network consent). Existing read-only grants do not implicitly enable writes.
`orchestration.dispatchCommand` accepts only `thread.turn.start` for a catalog
thread, checks `orchestration:operate`, and revalidates project/session/runtime
identity natively. A saved conversation can start its existing shared tab/runtime
without changing desktop selection; readiness waits up to 20 seconds and a
submission hold prevents idle collection/reload during startup. Busy sessions and
queued work are rejected, not silently queued or rerouted. Desktop drafts remain
untouched; the existing Pi model/account selection is preserved.

Text is limited to 256 KiB. Only inline PNG/JPEG/WebP images are supported (8
images / 8 MiB total); canonical base64 and sizes are checked in Node and actual
image types in Swift. Caller filenames, attachment URLs and arbitrary paths are
never used; native files get random private directories. Network RPC frames are
bounded to 12 MiB and native IPC records to 16 MiB. Attachments remain text-only
in projected snapshots; accepted temporary images stay available to desktop chat.
New-session bootstrap, file uploads, model-changing and other commands remain
unsupported and return typed command errors without disconnecting read streams.

Acceptance is returned only after Pi acknowledges the prompt. Command IDs and
payload hashes coalesce concurrent/reconnected submissions; outcomes, including
uncertain failures, are retained within the current service lifetime (256-command
capacity, no unsafe eviction). Native deduplication survives sidecar restarts;
full app restarts are NOT a durable exactly-once guarantee. On an uncertain error,
inspect the conversation before resending. Optimistic mobile message IDs are
mapped to stable transcript anchors so Pending can reconcile with real messages.

### Read-only session projection

Private IPC records are framed strictly by LF bytes in both Swift and Node.
Do not use Node `readline`: it can split literal U+2028/U+2029 inside valid
Foundation JSON strings, dropping catalog/transcript replies and causing timeouts.
The receiver preserves fragmented UTF-8 and bounds individual records to 16 MiB.

`workspace.catalog` and `session.read` are private IPC reads of existing native
objects. Catalog exports saved metadata and visible runtime ownership, not
composer text or full transcripts. Unsent draft sessions are excluded. Detail
reads match **runtime UUID + expected session path + expected project** atomically
on the main actor and reject replaced sessions. Loaded messages are read from
memory; catalog-authorized historical/configuring sessions are read off the main
actor from regular, non-symlink JSONL files whose header matches the project.
These reads follow the visible branch and never activate a tab, start Pi, restore
attachments or follow tool-output paths. Stable record/block IDs and a stat-keyed
text cache keep unchanged history subscriptions from republishing snapshots.

Shell threads carry `latestUserMessageAt` and are ordered newest first (stable ID
ties), using the catalog's last-user timestamp plus newer loaded user messages.
The mobile V2 list ignores wire order and sorts active rows by `activeOrderKey`
(or creation time if keyless). Pi Mac therefore exports a deterministic inverse
last-user-time arrangement key in both shell and detail schemas. Sending a new
message updates that key; opening history/tool output does not.

T3 HTTP exposes `GET /api/orchestration/shell` and
`GET /api/orchestration/threads/:opaqueId`, with `reasoningMessages=true` opt-in.
Read scope is required; authorization is rechecked after IPC before delivering a
possibly delayed HTTP response. Runtime IDs and session file paths are not
forwarded as thread IDs. Project roots remain authorized read metadata.

IDs hash environment identity, project path and saved session path. They survive
restart and idle runtime reuse while paths remain unchanged; moving files changes
IDs. Message IDs anchor reply slots to user-message order/text, preserving
assistant IDs through streaming/finalization and native history ID regeneration
for an unchanged branch. They are projection identities, not persisted Pi IDs or
future write authority. Compaction/branch reshaping can replace that projection.

A durable, atomic sequence watermark in `projection-clock.json` prevents sequence
regression across restart/clock rollback. **It stores no transcript or event log.**
RPC resume always sends a fresh complete fallback snapshot, not invented replay
or domain events; optional synchronized markers stay paired with their snapshot.
Polling runs every 500 ms only while watched. Queue capacity one coalesces full
snapshot/marker batches; cancellation/revocation shuts down background reads.

Budgets: 128 projects/runtimes, 2048 catalog sessions, 512 KiB catalog/projected
shell snapshot, 20000 entries and 8 MiB native/projected thread detail, 64 MiB
saved-session input files and a 32 MiB cost-limited history cache. Over-budget or
unreadable files fail explicitly, not with a truncated or falsely empty transcript.
Pagination/window requests are rejected and pagination is advertised false.
Reasoning and tool text/inputs are projected; image/file attachments and extension
UI answers are not. Pending native input is a flag, not a remote answer control.

### T3 RPC initialization and subscriptions

The reviewed `effect@4.0.0-rc.115` JSON RPC framing powers:

- `server.probe`, `server.getConfig`, `server.getSettings`;
- `subscribeServerConfig`, `subscribeServerLifecycle`;
- `orchestration.subscribeShell`, `orchestration.subscribeThread`.

Configuration uses the pinned original T3 schemas. It advertises completion
markers/reasoning but no pagination/uploads and **no fake Codex/Claude driver or
remote mutation provider**. Settings are inert client-compatible preview defaults,
not writable Pi/account configuration. Theme/quota opt-ins return empty sets.
Unknown RPCs fail without dispatching workspace mutations. The adapter does not
import the T3 orchestration engine or provider/session services.

Each socket is bound to its ticket's device session. Validation and capacity checks
precede ticket consumption. Revocation, expiry (deadline/traffic/one-second idle
check), EOF and shutdown interrupt scoped handlers. Unresponsive revoked peers
are force-terminated within one second. Limits shared across listeners: 16 sockets,
300 KiB incoming frames, 128 frames/second including batch weight, 16 outstanding
request IDs, eight handlers per socket, four workspace streams/socket and 32 total
workspace watchers. Compression/native ws addons are disabled. Slow consumers are
bounded/coalesced, rather than accumulating unbounded transcript replay queues.

## Ownership and crash recovery

Native `owner.lock` uses nonblocking OS flock and stays held until the actual child
exit. A second child-side exclusive `child-owner.json` marker is acquired **before
opening the auth store**, and removed only on actual Node exit. It prevents a new
supervisor from writing while an orphan child has not yet consumed stdin EOF.
Normal EOF handoff and concurrent replacement rejection are tested. The marker
contains only PID and a random nonce, not credentials.

SIGKILL can leave a stale marker. **No automatic lock stealing or state reset.**
If startup keeps failing after a forced crash: stop Pi Mac, verify that the Node
PID recorded in that marker and every other Pi Mac sidecar have exited, then move
only `child-owner.json` aside and restart. PID alone is not proof that a process is
our sidecar; do not kill unrelated processes. Never remove a live marker, `auth.json`
or the sequence clock as a quick fix. Additional crash/kill fault injection and a
safe recovery UI remain necessary before calling this production-ready.

## Build and tests

Node >=22.19 on the login-shell PATH (as required by Pi). Generated runtime and MIT
notices ship with Swift resources; application startup installs/downloads nothing.

```sh
npm --prefix sidecars/t3-rpc ci --ignore-scripts
npm --prefix sidecars/t3-rpc run build
npm --prefix sidecars/t3-rpc run check
node --test Tests/T3Bridge/*.test.mjs
swift test --disable-xctest --filter 'T3ConnectionModelsTests|T3WorkspaceReadModelTests|RemoteWorkspaceBridgeTests'
./scripts/package-app.sh
```

Current targeted tests: 58 Node and 22 Swift, including real Effect config/lifecycle
and snapshot subscriptions, source-schema validation, copied resources without npm
modules, delayed-read revocation, runtime reuse isolation, stream interruption,
private/public listener separation, same-endpoint/foreign Origin, child ownership,
and actual bundled child/pipes plus native device management. Fixtures use synthetic
credentials/traffic; these are **not iPhone App Store acceptance tests**.

The full Swift Testing run passes 163 tests in 42 suites. Unfiltered checks still
include unrelated legacy Telegram XCTest and formatting failures;
`--disable-xctest` does not validate that legacy bundle.

Local developer preview remains available:

```sh
export PIMAC_T3_BRIDGE=1
export PIMAC_T3_BRIDGE_TOKEN="$(openssl rand -hex 32)"
swift run PiMac
```

It logs only the ephemeral loopback port. Private diagnostics use
`POST /internal/request` and the admin bearer, with `{ "method": "workspace.snapshot" }`
or existing-runtime prompt/abort inputs. Outcomes that time out are **unknown**,
never permission to retry a mutation. UI startup clears inherited public-listener
environment variables; enable phone access through its explicit network controls.

## Audit and remaining milestones

Baseline: `pingdotgg/t3code` commit
`a97a4a9d189f145afe79c3a6f8533bbf9a6b40b1`, reviewed outside this repo in
`/tmp/PiMac-t3code`. `sidecars/t3-rpc/upstream/` contains the unchanged contract
closure with SHA-256 pins, not its engine. Independent generated validation
fixtures exercise full upstream snapshots/config contracts. Effect's upstream
patch concerns client instrumentation/MCP/browser HTTP, not this server framing.
MIT notice: `Resources/t3-bridge/T3-LICENSE.txt`; the auth store is Pi Mac code.

Next:

1. Verify the actual App Store build/version with the read-only connection. Record
   discovery, pairing, config/lifecycle, catalog/detail/streaming and Origin behavior;
   redact credentials from screenshots/logs. Protocol baseline tests are not proof.
2. Implement durable command receipts, then map T3 prompt/cancel through the single
   native workspace owner. Never automatically retry unknown outcomes.
3. Add validated historical activation/process policy, stable writable targets and
   branch/turn semantics without a second session-file writer.
4. Add pagination, attachments/tools/extension confirmation as separately bounded,
   explicitly advertised capabilities.
5. Expand forced-crash ownership/recovery tests, then harden deployment/network/TLS.
   T3 Connect/hosted services remain out of scope for this LAN preview.
