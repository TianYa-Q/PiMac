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
2. LAN opens automatically after Server readiness on an available physical
   private IPv4 interface (prefer `en0`), port **3773** by default. View/copy the
   address under **Settings → T3 iOS 连接 → 局域网直连**. The Server and
   administration remain loopback-only; the separately bound proxy exposes only
   authenticated upstream client routes. No available interface/occupied port
   is surfaced as a settings error rather than exposing a wildcard.
3. On the same trusted network, manually add the displayed address in T3 iOS
   and use a freshly generated upstream pairing credential. The UI also offers
   a pairing link/QR for clients supporting that format. LAN does not require a
   Relay account, managed tunnel, or second Server. App Store pairing/UI behavior
   still requires physical-device acceptance.
4. For remote access, authorize official T3 Connect with the same iOS account.
   LAN and Tunnel share **Pi Mac**, its environment ID, sessions and upstream
   DPoP/ticket/RPC authentication. Keep Pi Mac awake and online.
5. Pausing publication only pauses activity updates; unlinking revokes the Tunnel,
   not LAN. Closing LAN disconnects that transport but does not revoke issued
   phone grants. Revoke devices separately when required.

LAN defaults on. Endpoint preferences store only host/port under
`t3RememberedLANEndpointV2`, never credentials. Explicit disable persists in
`t3LANEnabled` and prevents reopening on restart. A saved address is reused if
still local; after address changes startup selects an eligible physical interface
and retains the saved port. Automatic selection excludes VPN/virtual interfaces,
public IPs and wildcard binds. Legacy endpoint data is not reused.
LAN HTTP is unencrypted: use trusted networks, no public port forwarding. The
proxy strips forwarding/control headers, checks peer/Host, and closes upgraded
sockets on disable/shutdown. Failed rebinding leaves the previous listener intact.

The iOS catalog is keyed by `environmentId`: registering Tunnel or adding a LAN
address can update the same saved environment entry. Labels cannot create two
independent environments, and Pi Mac does not invent another identity/engine or
guarantee automatic LAN/Tunnel fallback. Explicit endpoint selection and catalog
refresh behavior must be verified on the installed phone version.

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

Startup records port reuse/reassignment and managed registration retry phases.
Connector health summaries record finite classifications. Full cloudflared
connection output (including error text, target IPs, protocol, edge location and
retry messages) is also saved to private `server-owned/tunnel-connector.log`,
with one rotated `.1` file (2 MiB each, mode 0600, at most 64 KiB per line).
Only the connector token is replaced; network error details are not removed.
This detailed log is not embedded in settings/RPC summaries. It is produced by
the upstream output observer, including connector restarts, without enabling
HTTP request-body/header debug logging or dumping the process environment.
Logs reject symlinks, hardlinks and unsafe permissions; failures never interrupt
connection handling. DPoP failures include an allowlisted route, method and transport so URL
mismatches can be distinguished from Tunnel recovery without logging URLs/proofs.
Settings distinguish `connecting`, `connected` (Cloudflare edge registration),
and `reconnecting`; process `running` alone is not readiness. An edge connection
still does not prove public reachability, phone rendering or notification delivery.
The linked state now offers **重试恢复** without requiring logout/re-authorization.

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

Pi tool/file-change projection and token usage now use the unmodified official
Pi Adapter and contracts. Local diff enrichment, tool-parent inference and
assistant-duration/output aggregation patches have been removed. The desktop
uses official `turnTokenUsage` and turn timestamps when supplied; absent usage
means no output-speed display, not an inferred or host-injected metric. Upstream
Pi currently emits flat tool items and does not supply per-turn output usage.

The desktop currently reads native HTTP snapshots by polling. iOS uses upstream
shell/thread subscriptions and completion markers. Pairing or socket connection
does not prove that the phone rendered the catalog. The retired desktop-bridge
counter endpoint is no longer available.

Old JSONL transcripts and legacy authorization/identity stores are not silently
imported or rebound. Existing phone installations should remove the old LAN entry and enable Tunnel. New
threads use the Server-owned database and private per-instance Pi sessions.

## Mobile Usage / Limits

The host allowlist permits `server.refreshProviders`, `server.getUsageSummary`
and `server.refreshUsageRates`, used by the stock phone's Usage / Limits screen.
Limits refresh uses the official provider/source service, with upstream
`orchestration:operate` authorization; summary and pricing use
`orchestration:read`. No server administration namespace or HTTP routes are opened.
Previously the host rejected refresh even for authorized Tunnel sessions.

Usage now scans only the configured Pi agent's `sessions` tree, rather than
unrelated native CLI history. Final assistant usage maps input/output/cache
counts and reported costs into official aggregation, retaining day/hour/time-zone
filtering. Shared Pi entry IDs deduplicate forked transcript copies. Provider
categories describe the underlying model service; currently unsupported service
categories are skipped, not relabeled. Pi history outside this session tree is
not included.

Limits publishes the existing read-only Pi OAuth account queries (ChatGPT/Codex
and Antigravity) through the stock multi-account source envelope, labeled
`Pi accounts (read-only)`. The stock contract names this envelope `cliproxy`;
no CLIProxy hub is contacted. Remaining percentages become used percentages,
with Codex second-based and Gemini millisecond-based reset timestamps normalized.
Hidden accounts are omitted; tokens never cross the mobile protocol. No login,
auth refresh/write, account switching or reset-credit redemption is introduced.
Absent OAuth and query failures remain visible as notices. Queries share the
existing one-minute cache, and closed hosts abort outstanding queries.

Tests cover parsing, fork dedupe keys, quota conversion/redaction, and Tunnel
DPoP/ticket summary aggregation/source subscription and read-only refresh denial.
Physical-phone display still requires device acceptance.

## Git / VCS

The host now permits the explicit native `vcs.*` methods (status, refs, init,
branch switching/creation, pull, worktree creation/removal), `subscribeVcsStatus`,
worktree setup subscription/cancellation, the three `git.*` workflow methods
and the two live diff preview methods. This is not blanket namespace access;
terminal/shell/admin APIs remain closed. Upstream still enforces each RPC's
read/operate/review scope, including for progress streams and read-only phones.

Desktop **Git** beside the composer's compact control opens the selected thread's worktree,
or the project root for a root thread/draft. It offers branch/status/ahead/behind,
changed files and text diff preview (including truncation notices), selected-file
commit, commit-and-push, push, create PR, pull, and local branch creation/switching.
Commits require an explicit message and file selection; unrelated staged files
are not implicitly committed. Branch switching/creation and pull are disabled
with local changes. Mutations require confirmation, display credential-free
phase progress and block development reload. Unknown outcomes lock further
mutations until refresh; neither reconnect nor refresh replays a command. Git
hooks and remote credentials remain owned by the Server. No desktop shell Git
runner, private worktree binding or second state writer is introduced.

A narrow ReviewService build patch extends upstream's canonical-path workspace
boundary to active project roots and active thread worktrees read from the
native stores. Pi Mac's Server startup cwd is its private state directory, not
a user project. Unregistered external roots and symlink escapes remain denied;
the original configured roots and upstream file-path validation are preserved.

Desktop layout includes a resizable sidebar with its width saved in UserDefaults
and restored across launches. No conversation header takes up transcript space;
Git sits to the right of compact, and a compact live Server connection badge sits
beside Pi Mac in the sidebar. Sidebar width is bounded to 250–360 points
(292 by default). The empty
conversation only shows the welcome text/project picker, without starter suggestions.
The transcript/editor subtree stays alive across page/tab changes and resizing.

Tests cover real local Git repositories and bare remotes, selected-file commit
streams including unrelated staged files, push/pull/refs/worktrees/diff, canonical
root denial, Swift WebSocket chunk acknowledgements, unknown-outcome locking,
and mobile DPoP/ticket status subscriptions and scope denial. Hosted PR creation,
Git credential prompts and physical-phone UI still require manual acceptance.
Rebuild the Server bundle before testing or packaging these changes.

## Scheduled tasks

The stock phone's Scheduled Tasks screen can list/subscribe, create/edit, enable/
disable, delete and run tasks immediately through the six official
`scheduledTasks.*` RPCs. Upstream retains `orchestration:read` checks for reads
and `orchestration:operate` checks for mutations; no scheduler HTTP routes or
blanket namespace access are added. The previous host allowlist rejected these
RPCs with a misleading missing-scope error, even for authorized sessions.

Schedules, run metadata and restart persistence belong to the official Server,
not a new Pi Mac timer. Interval schedules have a one-minute minimum; fixed-time
schedules use the Server's local wall clock. Pi Mac must stay running and awake.
The desktop's sidebar calendar button opens the same Server-owned task list.
It supports create/edit, pause/enable, delete (with confirmation) and run-now
(with confirmation), with next/last dispatch times and errors. The form offers
intervals or wall-clock time/weekdays, project/provider/model selection and either a new
conversation per run or an existing thread. Interval shortcuts offer 15 minutes,
one hour and 24 hours; fractional-minute intervals retain their display precision.
Changing provider requires choosing a model again to avoid cross-provider mismatches. New tasks use the project root and
full-access/default mode; edits retain the original project, workspace strategy,
access mode and model options (changing model clears old options).

The list polls every three seconds while open, pausing during edits. Connection
loss and unknown mutation outcomes are surfaced, without automatic mutation
replay or optimistic state. Refresh the list before another operation after an
unknown outcome. Swift tests exercise validation, policy preservation and the
actual desktop RPC transport through official Server dispatch into fixture Pi.

Regression tests cover mobile DPoP/ticket reads, subscriptions, edits and enable/
disable/delete, read-only mutation denial, and immediate execution into fixture
Pi with persistence across Server restart. Hosted relay/physical phone acceptance
and waiting for a real recurring deadline are not covered by these tests.

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
uses the same shutdown barrier. Before an update reload sends EOF, it writes the
upstream `server-owned/runtime/desktop-update-restart` marker: shutdown consumes
this one-minute marker and preserves the managed tunnel for the replacement.
Normal quit does not write it and still releases the tunnel. This can require
provisioning a replacement and Cloudflare route propagation on the next launch;
port stability does not eliminate that upstream lifecycle or network outages.

The private `server-owned/loopback-port.json` stores the actual listening port
(version 1, mode 0600, atomic replacement). Normal/update restarts reuse that
loopback-only port, allowing upstream's confirmed-origin fast path instead of
forcing first-registration jitter on every boot. An occupied port selects a new
origin and lets upstream re-register; it never kills/probes the other owner or
resets identity, history or phone authorization. Malformed/unsafe port state is
rejected rather than silently overwritten. The port availability check cannot
transfer its socket to upstream: an intervening bind race fails startup safely,
and a failed startup never commits a new origin.

Protocol selection, edge reconnect/backoff, token/tunnel configuration changes,
and Relay recovery remain upstream-owned. Pi Mac does not pin HTTP/2, run an
outage watchdog, kill stalled connectors, or suppress upstream recovery requests.
Health/output hooks are observational only. Upstream's config identity includes
both connectorToken and tunnelId, so a recovered token change replaces the child
even when the tunnel ID stays the same. A local process respawn alone is not a
Relay credential refresh.

The connector follows the user's existing routing rules; Pi Mac itself does not
edit global proxy configuration. Fake-IP addresses alone do not prove traffic
uses a proxy node: Clash can still select DIRECT. Fake-IP DNS can collapse each
regional edge pool to one synthetic address, reducing four HA connections to two.
A scoped fake-IP exclusion for `+.argotunnel.com` can restore address diversity,
but is not proof that DNS caused TLS EOF. Do not disable TLS verification or
post-quantum security to mask unexplained EOFs.
Regression tests cover repeated real Server restarts with unchanged origin,
persistent phone DPoP authorization and WebSocket tickets, occupied-port recovery,
unsafe port files, and patched official connector output/crash/unlink transitions.
These tests do not contact hosted relay or replace physical-phone acceptance.
The stock phone's `server.reportClientActivity` is narrowly allowed so upstream
background subscription policy receives visibility/liveness; host power/process
administration remains closed.

A rapid relaunch waits up to 15 seconds for the
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

The preparation step verifies 1,745 pinned upstream files and bundles the real
Server; it does not launch Pi or download anything at app startup. Native Server
integration tests use a protocol-only Pi fixture without real accounts/models.
The retired bridge tests are not part of the new verification chain.
