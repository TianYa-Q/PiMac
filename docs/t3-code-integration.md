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
2. Open **Settings → T3 iOS 连接**. The local Server starts with Pi Mac even when
   LAN access is disabled.
3. Explicitly enable LAN access on a current local RFC1918 IPv4 address (default
   port 3773). Invalid/nonlocal addresses or occupied ports fail visibly; there is
   no wildcard, public-IP, DNS, CGNAT or silent alternative listener.
4. Generate a one-time pairing code. Enter the displayed HTTP address and the
   complete code in T3 iOS, or scan the QR inside T3 iOS. Pairing uses the upstream
   12-digit code; the pair URL keeps it in `#token=…`, not a query.
5. The unused grant expires after five minutes and is revoked when the panel
   closes or replaces it. Authorized devices can be revoked from the panel.
6. Disabling LAN closes remote access, **not** the local Server or running tasks.
   Explicit disable clears remembered network consent. App shutdown preserves it.

LAN HTTP is plaintext, including bearer credentials and transcripts. Use a
trusted LAN only; never add router port forwarding or share pairing codes.
The separate public proxy never serves `/internal/`. The supervisor credential
is local-only and is not passed to Pi tools/extensions. TLS, IPv6, Bonjour and
managed tunnels are not implemented.

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
imported or rebound. Existing phone installations may need to pair again. New
threads use the Server-owned database and private per-instance Pi sessions.

## Experimental T3 Connect notifications

The existing publish-only integration uses official hosted OAuth/PKCE and signed
activity publication; chat stays on LAN. Enable it separately in settings and
use the same T3/Apple account as the phone. The callback listens only on
`127.0.0.1:34338`; an occupied port fails closed.

Only title/model/phase/timestamp/opaque-link metadata is published, not prompts,
reasoning, tool bodies or attachment data. Titles can contain sensitive text.
Credentials and signing material are privately stored, not in UserDefaults or
logs. Pause stops new publishing; it cannot recall already queued notifications.
Logout requires acknowledged unlinking; failure retains credentials for an
explicit retry. A successful publish or registered-device count does not prove
that an iPhone displayed a notification.

Real Apple login, APNs, Live Activities and App Store compatibility still need
physical-device acceptance. Approval/input notifications and hosted chat are not
implemented.

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
