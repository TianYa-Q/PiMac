# T3 Code upstream maintenance

## Current upgrade

- Repository: https://github.com/pingdotgg/t3code, release tag `v0.1.0` (not floating `main`).
- Previous pin: `26fffe5aee22ea9bdd39c5b4c400f643c560b4a0` (2026-10-15 UTC).
- New pin: `81493efb71e8e8244f95d3e9f71d8369654ab151` (`v0.1.0`, 2026-10-15 UTC).
- The release adds six commits, including ACP malformed-session-update recovery
  and HTML-render caching. The manifest includes the three new ACP fixture files;
  existing host patches still match unchanged. Dependencies are unchanged.
- The source fetcher's safe filename validation now accepts `@`, required by
  the already-pinned native dependency patch filenames; traversal checks remain.
- The commit, pristine source hashes and dependency catalog are recorded in
  `sidecars/t3-server/upstream-pin.json`. Generated sources/bundles and installed
  dependencies are not source-controlled.
- Effect and its Node platform dependencies advance together to `4.0.4`.
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
- Enter's `deliveryIntent: steer` queues durably while a native `/compact` run
  is active, resolved under the official thread dispatch lock. Explicit
  `steer_active`/`restart_active` still use upstream validation; Provider compaction
  execution and queue draining remain upstream-owned.
- Atomic parent/descendant settlement and bounded subtree identity lookup,
  retaining validation, cycle handling and archived/deleted-node exclusion.
- Mobile first-message title compatibility for native drafts without titleSeed.
- Background Pi text generation retains user extensions so extension-registered
  Providers (for example `pi-antigravity`) remain available. Ephemeral sessions,
  disabled built-in tools and T3 MCP credential isolation are preserved. This
  does not sandbox user extension code; extensions retain normal Pi behavior.
- Review of active externally bound worktrees, supplementing official root
  validation because the host cwd is its private state directory.
- Pi quota sources for stock mobile Limits; usage history and image output now
  use upstream implementations rather than duplicated local patches.

Remove compatibility patches as upstream covers their behavior. Do not turn an
upgrade into an alternative Provider engine or a new PiMac permission system.
Archive an old upstream cache before restoring a new pin; never bypass hash
validation, overwrite local changes, or restart an active production Server.

## Validation

For the `v0.1.0` pin update, all 2,078 pristine source hashes and existing patch
anchors pass, together with all six upstream-maintenance tests, JavaScript syntax
checks, targeted TypeScript `--allowJs --checkJs --noEmit`, and `git diff --check`.
The bundle/native-runtime check reports stale local generated runtime artifacts;
no build, full bundled-Server test run, app restart or live-state migration was
performed for this pin-only update. Regenerate and validate artifacts before
publishing the release-pinned runtime.

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
