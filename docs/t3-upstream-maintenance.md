# T3 Code upstream maintenance

## Current upgrade

- Repository: https://github.com/pingdotgg/t3code, stable release tag `v0.1.3` (not floating `main`).
- Previous pin: `81493efb71e8e8244f95d3e9f71d8369654ab151` (`v0.1.0`).
- New pin: `d2c440312e5f39d59827ed466838a623516454d6` (`v0.1.3`, published 2026-10-27 UTC).
- The manifest includes 2,186 pristine files, including the new fx Provider,
  shared source-control definitions, and checked-in GraphQL schemas required by
  the new Server and GitHub implementation. Markdown math and document parser
  dependencies are explicitly locked; no upstream capability is stubbed out.
- Preserve upstream's new Muse process-exit hook and patched math tokenizer,
  including its npm alias, nested dependency paths and default-export redirect.
  Apply npm patches only to isolated copies used for staging/bundling.
- Rebase host patch anchors onto upstream's Effect.fn/read-only-store refactors.
  Keep upstream Pi model-inventory validation and authorized-client observation.
  Remove the old Codex enabled-flag and review-worktree patches: upstream now
  preserves the flag and validates registered Git worktrees in KnownWorkspaces.
- Native desktop/pairing credentials now use upstream `AuthStandardClientScopes`,
  which replaces the former administrative set. Existing grants are not expanded;
  upstream authentication and per-request authorization remain authoritative.
- The worktree RPC now requires `path: null` and chooses a managed location;
  protocol fixtures exercise that contract rather than bypassing it.
- The commit, pristine source hashes and dependency catalog are recorded in
  `sidecars/t3-server/upstream-pin.json`. Generated sources/bundles and installed
  dependencies are not source-controlled.
- Effect and its Node platform dependencies advance together to `4.0.5`.
  Orchestration protocol remains 2.
- Upstream extracted providers and source-control implementations into workspace
  packages. Local presentation/host patches follow those packages rather than
  recreating the removed Server modules. The new outer process-runner layer
  receives Node services before starting upstream.
- This is a Server source revision, not an iOS build number or a verified
  build-to-commit mapping. Physical-device acceptance remains separate.

## Product boundary: a personal UI over official T3

PiMac is a single-user UI and host integration for the official Server. It must
not introduce its own model lock, delegation target filter, endpoint allowlist,
Provider restriction or terminal/search capability disablement. Upstream owns
capability discovery, Provider configuration, permission modes, authentication
and RPC/HTTP scopes. User settings and actual installed/authenticated Provider
availability still apply; absence of credentials is not a reason to fabricate
availability or bypass upstream checks.

The former parent-model-only MCP catalog/delegation patches are removed.
Ordinary and delegated work can select the officially available instances and
models. The host also preserves the official browser launcher for ordinary
links and other Provider authorization flows; it captures only a desktop-started
T3 Connect login for the native authorization UI.

Upstream authentication, credential isolation, transport protections and private
supervisor administration are retained. This does not mean exposing an
unauthenticated Server or passing supervisor secrets into Provider processes.
Pi account quota snapshots remain a data-source integration: they do not invent
redemption credentials or implement unsupported account operations.

## Remaining presentation / host patches

- Native supervision, readiness, loopback/LAN/tunnel transport integration,
  credential-safe subprocess environment and private desktop administration.
- A lazy dedicated read-only SQLite worker for credential lookups, independent
  of the bulk-history reader. No identity caching or auth-policy change; existing
  SQL transactions preserve their connection and visibility. Retain the official
  worker fallback and scope cleanup when rebasing `nodeSqliteClient.ts` and
  `AuthSessions.ts`. The HTTP regression uses real file-backed transactions.
- Managed tunnel health/publication diagnostics; lifecycle and recovery remain
  upstream-owned, including the upstream readiness supervisor.
- Desktop model visibility preferences and metadata discovery for model context
  settings; visibility is not a runtime authorization rule.
- Pi-only discovery defaults through official disabled instance/project settings,
  with a backed-up one-time migration and disabled-row presentation filtering.
  Native installers initialize on demand; background installation subscriptions
  and usage discovery follow official enablement. Managed Codex pending snapshots
  also copy the instance's enabled flag (not the raw config default), so disabled
  managed installs do not reappear as enabled status rows. All drivers, runtime APIs
  and scopes remain intact; later official settings can enable any provider.
- Pi response telemetry, account-selection status and Fast option integration.
- Authenticated native Pi HTML export through the existing session manager,
  including restart/resume without a user message or model run. A command-only
  extension reads the effective system prompt; the host fills just the native
  HTML data field because Pi 1.3 still exports the legacy empty agent-state
  prompt. Missing metadata or an unknown template fails explicitly; native
  rendering, tools, transcript and branch data remain Pi-owned. See the sidecar
  README for the scope and private temporary-file boundary.
- Optional pinned `pi-goal-x` presentation bridge: validate RPC status reports and
  mirror them into official `providerThread.goal`; extension scheduling/storage
  and upstream Pi lifecycle remain unchanged. See [Pi Goal](pi-goal.md).
  Pi transport, cancellation, retry and compaction remain official.
- Optional `piMetrics` wire projection and scalar latest-message timestamps for
  desktop presentation; no message bodies are added to the shell projection.
- Native `/compact` follow-up queueing is now entirely upstream-owned. Upstream
  queues both Enter's `deliveryIntent: steer` and explicit `steer_active` during
  maintenance; the old host queueing patch is removed. Restart validation,
  Provider compaction execution and queue draining remain upstream-owned.
- Atomic parent/descendant settlement and bounded subtree identity lookup,
  retaining validation, cycle handling and archived/deleted-node exclusion.
- Mobile first-message title compatibility for native drafts without titleSeed.
- Background Pi text generation retains user extensions so extension-registered
  Providers (for example `pi-antigravity`) remain available. Ephemeral sessions,
  disabled built-in tools and T3 MCP credential isolation are preserved. This
  does not sandbox user extension code; extensions retain normal Pi behavior.
- Review root and registered external-worktree validation are now entirely
  upstream-owned through KnownWorkspaces; no host path-authorization patch remains.
- Pi quota sources for stock mobile Limits; usage history and image output now
  use upstream implementations rather than duplicated local patches.

Remove compatibility patches as upstream covers their behavior. Do not turn an
upgrade into an alternative Provider engine or a new PiMac permission system.
Archive an old upstream cache before restoring a new pin; never bypass hash
validation, overwrite local changes, or restart an active production Server.

## Validation

For the `v0.1.3` update, regenerated the Server bundle and darwin-arm64 native
runtime (126 packages). All 2,186 pristine hashes and sequential patch anchors
are checked. Protocol regressions cover the official managed-worktree RPC,
standard client grants and full Provider/MCP catalog, including fx.
A clean `npm ci --ignore-scripts` followed by `npm run check` reproduces the
bundle/native runtime. The real bundler regression validates four math delimiters,
literal prices/shell variables, display metadata and math inside table cells.
Build/management JavaScript syntax, targeted TypeScript `--allowJs --checkJs
--noEmit`, the new TypeScript test's typecheck and `git diff --check` pass.
Final serial regressions: all **157** sidecar tests and all **73** selected Swift
T3 integration/presentation tests pass (`swift test --jobs 1 --no-parallel --filter T3`).
No running app/Server restart, live-state migration or production publication
is part of this source/runtime preparation.

Dependency audit remains a known upstream follow-up: `npm audit` reports 9
package findings (3 low, 2 moderate, 4 high; no critical), including propagated
Cursor SDK/Zod findings, body-parser, fast-uri, stream-json, undici and the math
parser/KaTeX chain. Counts include transitive propagation, not nine independent
exploits. No `npm audit fix` or out-of-release SDK upgrade was applied; these
findings do not establish exploitability, but this update is not a security
clearance. Audit output is retained with the task's temporary validation logs.

```sh
./scripts/prepare-t3-server.sh
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
swift test
```

Previous main-snapshot upgrade validation passed: reproducible bundle/native-runtime check, all **123**
Server tests, all **431** Swift tests, and all **32** development-watcher tests.
An isolated standalone runtime smoke also exercised SDK imports, real PTY output,
indexed workspace search and native content grep. Protocol fixtures explicitly
isolate account/data roots and background text generation; an independent
upstream `codex --version` probe is caught by a rejecting fixture executable,
never the developer's installed CLI.

`upstream-maintenance.test.mjs` verifies pristine hashes and sequential patch
anchors, including modules not currently reached by the bundle. Protocol tests
exercise persistence/restart, scheduling, model selection/delegation, native
Git, DPoP, official scope denial, attachments, images and mobile transport.
Native runtime dependencies must also travel with the standalone app; see the
sidecar README for staging and build-host architecture requirements.

Test fixtures do not establish real-model, public tunnel, physical-device or
App Store acceptance. No live production state is migrated or application
restarted by this upgrade task.
