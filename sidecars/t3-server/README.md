# Official T3 Server sidecar

Pinned upstream: **v0.1.3 stable release**, `pingdotgg/t3code@d2c440312e5f39d59827ed466838a623516454d6` (published 2026-10-27 UTC).
This uses upstream orchestrator V2 and all official Provider drivers, including
Pi's package-owned driver, adapter and RPC transport. A presentation-focused Pi adapter patch records per-message usage and
model-response duration (excluding tools), exposing normalized turn usage and
optional `piMetrics` through the V2 contract after each assistant `message_end`,
without waiting for task settlement or context statistics. The displayed speed uses an AA approximation (`speedMethod: aa-approx-v1`):
streamed first-to-last chunk timing, excluding the boundary chunk's estimated
share. Per-chunk character weights are calibrated against actual output usage,
not a fixed characters-per-token guess. Codex/Responses thinking is a summary,
so hidden reasoning tokens are subtracted (not double-counted), and the final
~80% of visible chunks is measured. Full reasoning streams are included for
other APIs. Only valid samples contribute to the task's time-weighted average;
short/buffered streams, missing reasoning counts on Responses, and unstreamed
tool-call payloads do not manufacture a speed. Billing/context remain separate.
Lifecycle remains upstream-owned. Parent settlement discovers descendants through a
thread-ID-only recursive query, not a full shell projection per command. Cycle
protection and archived/deleted-node exclusion are preserved; the original
per-thread checks and atomic subtree event commit still own correctness.
The former custom Pi
adapter, transport, runtime controls, and their tests have been removed.

Pi Mac retains host integration and management: loopback Server/administration,
a default-on LAN HTTP/WebSocket transport, supervisor credentials, managed T3
Connect, diagnostics, and desktop model preferences. Official T3 owns endpoint
routing, authentication, scopes and capability declarations; no PiMac RPC/HTTP
allowlist or capability replacement is applied.
LAN shares upstream authentication and the same environment identity; it never
publishes administration routes or introduces another orchestration engine. The supervisor has no workspace/Pi command API.
Provider subprocesses must not inherit supervisor secrets.
For this single-user app, newly issued desktop sessions and explicit phone
pairings use upstream `AuthStandardClientScopes`, including access/relay
management and all granular file/settings/diagnostic permissions. Existing
phone grants are not silently expanded: create a fresh pairing after upgrading.
Explicitly narrower OAuth scope requests remain narrower, as enforced upstream.

Pi's upstream-owned extension discovers T3 tools through `POST /mcp`, including
`schedule_task` for chat-created timers. Upstream validates the thread-bound
MCP bearer credential without an additional PiMac endpoint gate. Missing,
invalid, and supervisor credentials are rejected by upstream. PiMac is a
single-user UI over official T3, not an additional permission system.
`orchestrator_capabilities` exposes the official catalog and `delegate_task`
uses official target/inheritance semantics, including explicit alternate
models and providers. No PiMac parent-model lock or delegation allowlist remains.
Existing processes need a safe runtime reload/session reopen after publication
to load the updated Server; never interrupt active work just to publish it.

## Reproducible build

Commit host sources, patches, tests, dependency locks, and `upstream-pin.json`.
The manifest hashes 2,186 upstream files, including native dependency patches
and checked-in GraphQL schemas. Effect and its Node platform packages are pinned
together at `4.0.5`.
`upstream/`, `node_modules/`, `generated/` and the app's generated
`vendor/t3-server.mjs`, `vendor/node_modules/` and `vendor/native-runtime.json`
are build artifacts.
The upstream MIT license is copied to `vendor/T3-SERVER-LICENSE.txt`.

```sh
./scripts/prepare-t3-server.sh
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
```

Offline restore from a checkout containing the pinned revision:

```sh
node sidecars/t3-server/fetch-upstream.mjs --source /path/to/t3code
```

The fetcher refuses to overwrite a changed or incompatible upstream cache.
When deliberately changing the pin, archive the existing cache first.

## Native providers, terminal and workspace search

All official upstream drivers and usage readers remain registered (including
Codex, Claude, Cursor, fx, Grok, OpenCode, Antigravity, Pi, Muse and ACP registry).
PiMac does not replace terminal spawning, indexed workspace search or SDK loading
with disabled stubs. Provider **discovery defaults** are Pi-only: official default
instance slots for other drivers are explicitly disabled in settings, and disabled
status rows are omitted from phone snapshots/subscriptions. Installation services
initialize lazily; their background subscriptions and usage-history/account scans
follow official instance/project enablement. This avoids Codex/Claude version,
installation and usage probes by default without removing any driver or runtime API.

Existing settings migrate once: `settings.json.before-pi-discovery-v1` preserves the
exact pre-migration settings, then `settings.json.pi-discovery-v1` records completion.
The migration turns off non-Pi instance/project enablement but retains their configs,
credentials/environment references, models and all unrelated capability settings.
Later official `server.updateSettings` changes are not reset on restart: enabling a
native instance restores its discovery and visible status. Explicit installation
operations remain available under upstream administrative authorization. This is a
single-user preference, not the retired Pi-only authorization/delegation whitelist.
Upstream credentials and installation requirements still apply; enabling a driver
does not manufacture an installed CLI or an authenticated account.

`build.mjs` keeps disk-backed SDKs/native libraries external and stages their
lock-verified runtime dependency closure into `vendor/node_modules`, beside the
server bundle. SwiftPM's existing `.copy("Resources/t3-bridge")` includes it in
the standalone app. No runtime dependency on this checkout's `node_modules` is
required. The upstream pinned `fff-node` FFI fixes, `node-pty` helper fixes and Muse
process-exit hook are applied only to staged copies, never to pristine caches.
Upstream math parser npm patches (including the LLM tokenizer alias and its
patched default entrypoint) are applied in isolated copies used by the bundler;
installed dependencies stay pristine.
Installation uses `npm ci --ignore-scripts`; platform binaries must already be
present in the locked npm packages. Missing binaries fail the build rather than
silently disabling functionality or downloading an unpinned fallback.
`npm run check` verifies the bundle plus every native-runtime file hash/mode.
The current darwin-arm64 runtime closure is approximately 356 MB.

Build/package separately on each target architecture with matching Node.js 24+
and Swift tooling; universal/cross-architecture app packaging is not supported.
The application's Node runtime must use the same architecture as the build.
`scripts/package-app.sh` checks the app/Node architecture and signs nested Mach-O
addons, libraries and helpers before signing the outer bundle. The generated
runtime is excluded from the development watcher's runtime-input fingerprints;
editing/building it does not restart an active application.

## Startup readiness diagnostics

Supervisor `ready` is emitted only after both native management construction and
upstream's command-ready gate, not after a successful environment-descriptor GET.
The desktop observes that event immediately instead of waiting for its next
connection poll. Native launch uses one interactive login shell and marks the
inherited environment prepared, retaining upstream PATH hydration for other hosts.

`server-owned/startup-diagnostics.log` records one launch ID, PID, wall-clock and
monotonic timings for PATH hydration, settings, legacy-shell import, runtime and
delegation recovery, worker startup, HTTP/activation barriers and final readiness.
It logs phase starts as well as success/failure so unfinished stages remain visible.
Files are private, rotate at 512 KB with one prior copy, and contain no session or
authorization payloads. The first two minutes also time the official session
verification handler, distinguishing post-ready auth stalls from startup recovery.
Logging never changes official recovery or auth outcomes.

Credential lookups use a separate lazy SQLite read-only worker, so background
history/shell read transactions cannot block authentication on the shared reader.
It reads the same WAL without identity caching; signatures, expiration, revocation
and scopes remain upstream-owned. Existing transactions retain their original
connection and uncommitted visibility. Unsupported reader environments keep the
upstream writer fallback; this cannot promise contention isolation there.
`tests/auth-startup-contention.test.ts` runs the actual official HTTP auth handler
against a temporary file database with controlled reader/writer/both transactions,
including first-use auth, revocation, corrupt rows and write-transaction rollback.
Regression: `tests/startup-readiness.test.ts`, native `T3ConnectionRecoveryTests`,
`T3DesktopTests` and `T3LifecycleTests`. Real-state cold-start timings still require
a safe updated-app restart; isolated fixtures do not establish those timings.

The Swift client's session/stream contract and official source references are
recorded in [Native T3 client transport](../../docs/t3-client-transport.md).

## Protocol / upgrade

Pi account Limits also project Codex/OpenAI banked resets to the stock mobile
`usageLimits.resetCredits` contract: available count and earliest reported expiry
(normalized from Unix seconds to ISO). Missing/invalid metadata is omitted without
hiding quota windows; zero remains zero. Credit IDs, titles and redemption inputs
are not fabricated by this quota-data adapter. It has no Pi redemption backend;
this is not a host authorization gate on upstream Provider operations.
The stock mobile UI gates its dedicated credit card on redemption capability.
For compatibility without rebuilding iOS, Pi accounts additionally put an
explicitly labeled read-only reset summary in the existing account `plan`
display field (not an actual subscription-plan assertion). Mobile already
renders that field in account details and composer usage cards. This fallback
shows count and all valid reported credit expiries, sorted chronologically and
formatted in Beijing time (`Asia/Shanghai`, labeled UTC+8), retaining duplicate
expiries for separate credits. Unknown expiries are not invented. The standard
`nextExpiresAt` remains the earliest expiry in ISO UTC. This display fallback
does not add a redeem button or a live countdown. No fabricated credit IDs
or redemption capability are introduced. Restart the updated Server and refresh
mobile Limits; mobile rendering still requires physical-device acceptance.

Clients require orchestration protocol **2**. A mobile EAS build number is not
a Server version or a verified mapping to this commit; physical-device
acceptance remains pending. Upstream's `orchestration.getTurnItem` provides lazy
full-tool-detail fetch with official scope and thread/item isolation. Project mutations and orchestration
commands use official Effect RPC; HTTP serves V2 shell/thread projections.
`settings-migration.mjs` backs up obsolete launch settings and converts only
legacy `binaryArgs`, removing old host-injected extensions. Upstream owns
SQLite and V1 transcript migration; do not reinterpret old private Pi cursors
as native file paths. Back up real Server state before first upgraded startup.

The desktop uses official runtime requests for extension dialogs and `/compact`
for compaction. Session HTML export calls Pi's native `export_html` RPC through the
same official session manager. After a Server restart, the persisted active Pi
provider thread is restored with its workspace, instance settings and model
selection before exporting, without dispatching a user message or creating a run.
An injected command-only extension reads `ctx.getSystemPrompt()` (never a model
request). Its correlated status reply fills the native HTML data block because
Pi 1.3's exporter reads the legacy `agent.state.systemPrompt`, which can be empty
after restore. Missing extension/unsupported template/metadata timeout fails
explicitly rather than falling back to a model prompt or incomplete export.
The system prompt and tools are the effective restored configuration, not a
claim to recover their historical versions. Empty/non-Pi threads and missing
native files fail explicitly; there is no JSONL-only fallback that silently
omits system metadata. The authenticated orchestration-operate HTTP route returns
HTML as no-store JSON download data, never executes it or accepts a client path;
private temporary files are cleaned up. Desktop saving is atomic and warns about
sensitive conversation/system/tool data. Arbitrary tool output, full diffs and image bytes are not
embedded into shell snapshots; tool image metadata and signed downloads now
use upstream's implementation. Terminal-only decoration and old private
account/compaction-model overrides are not preserved; Fast uses the bounded
Pi extension integration described in the maintenance guide. The host observes only
`account-usage-gui` session-selection metadata before upstream ignores status
updates. It keeps thread/provider bindings in memory (no tokens or quota payloads)
and returns them through the private desktop account-status socket. Lightweight
selection reads are independent of the 60/180-second quota refresh cadence; they
never infer a binding from global `auth.json` or the future-session default.

## Account runtime ownership

`account-runtime.ts` is owned by the PiMac gateway, not by a Pi conversation.
It starts fixed one-minute checks when the supervised Server becomes ready and
stops/drains with the gateway. Startup and macOS wake trigger a catch-up sample.
Desktop account queries, background checks and mobile limits use this same runtime.
Private account-control IPC backs a persistent native account workspace without
sending `/accounts` to a thread. Snapshot, default-account, explicit visibility,
delete, refresh and health operations return structured state; activation records
are part of the snapshot, not transient notifications. Only official OAuth uses
a polled login flow, with prompts rendered inside the same workspace. Reauthorization
is explicit and preserves the future-session default. Login reuses the installed
Pi's official OAuth implementation and a stable PiMac device ID; managed credential
refreshes use the shared locked store.
Global native auth remains Pi-owned and is never replaced by a host login.

Only session authentication, session-local switching, boundary-safe rotation and
one confirmed-quota-error continuation remain in the extension. Sessions read
validated, identity-keyed host snapshots, never query quotas or send `你好`.
The host records eligibility, skip reasons and results in the private bounded
`pimac-account-monitor.jsonl`; see `extensions/account-usage/README.md` for policy,
retry behavior and storage details. The reusable storage/policy library remains
shared rather than duplicating credential parsing in Swift.

See `docs/t3-server-migration.md` for capabilities, limitations and acceptance
boundaries, and `docs/t3-upstream-maintenance.md` for the upgrade and patch audit. Protocol-fixture tests do not prove real-model or App Store acceptance.
