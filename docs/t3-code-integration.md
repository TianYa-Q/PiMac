# T3 Code iOS integration

Desktop, Telegram and the unmodified T3 iOS client now use one native T3 Server:

```text
SwiftUI / Telegram / iOS → T3 orchestration → Pi Provider Adapter → Pi runtime
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
selection and cancellation. The Adapter supports explicit full-access/default
mode only. Images use T3 attachment storage (PNG/JPEG/WebP, 8 images / 8MiB total).
Unsupported sandbox/approval, plan, rollback, terminal/worktree operations and
extension dialogs fail explicitly rather than falling back to desktop RPC.
Command acceptance is not task completion; unknown outcomes must be inspected
before resubmitting. `agent_settled`, not `agent_end`, determines completion.

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

The supervisor holds `owner.lock` until the Node child exits. A child-side
`child-owner.json` marker prevents an orphan from sharing the state directory.
EOF shuts down the scoped Server and Pi runtimes. No automatic lock stealing,
state reset, history activation or uncertain prompt replay is performed.

After a forced crash, verify that the recorded child and all related sidecars
have exited before moving a stale marker aside. PID alone is not proof of
identity; never kill unrelated processes or remove live locks/credential files.

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
