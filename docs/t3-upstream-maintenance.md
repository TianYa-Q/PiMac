# T3 Code upstream maintenance

## Current upgrade

- Repository: https://github.com/pingdotgg/t3code, branch `main`.
- Previous pin: `8d846660cecfc69ef4e192322fced29fa07f374c`.
- New pin: `442735897f6f92af33798075baa12d4fd4d710dd` (2026-10-06 UTC).
- Target client: T3 iOS build **109**. EAS manages build numbers remotely;
  this is an upgrade target, not a verified build-to-commit mapping.
- SHA-256 manifest: 1,798 pristine upstream files, including the workspace
  dependency catalog. Generated caches and bundles are not source-controlled.
- Effect/platform dependencies advance together to `4.0.1`, following upstream.
  Host/test imports use the stable `effect/http`, `effect/rpc`, `effect/socket`
  and `effect/process` paths. Orchestration protocol remains 2.
- Server composition patches follow the renamed upstream layers. Connect
  reconciliation now calls the official `CloudLink` service rather than a
  retired HTTP-module helper.
- Explicitly allow `orchestration.getTurnItem` for lazy full-tool-detail reads;
  tests cover successful retrieval, missing items and cross-thread isolation.
  New secret/webhook administration methods remain denied by default.
- Archive the previous upstream cache before restoring the new pin; do not
  bypass fetcher's hash checks or restart an active production Server.

## Official implementations, not local enhancements

At the upgrade baseline, PiDriver, PiRpc, PiAdapterV2 and wire contracts were
unpatched; subsequent bounded presentation exceptions are listed below. Removed the
local file-change detail/diff helper, tool-parent inference, output-usage helper,
assistant-duration wire field, and their helper-only tests. Native tool events,
file changes, token usage, steering, cancellation and settlement use official
projection semantics. Desktop tests cover flat Pi tool items and absent output
speed instead of depending on the deleted enhancements. If upstream supplies
`turnTokenUsage`, the desktop can use its official turn timestamps; it does not
inject missing usage.

Upstream authorizes RPC scopes in connection-scoped group middleware. PiMac no
longer adds an RPC/HTTP endpoint allowlist or replaces capability declarations;
credential-free diagnostics observe the official result, including streams. The retired per-handler
scope wrappers in `ws.ts` are no longer patched. Dynamic device-list checks and
HTTP authorization remain upstream-owned.

Provider model visibility follows the new config snapshot layout. Pi-only
mobile history integration preserves Pi dedupe keys with upstream's new
multi-file Codex deduplication path. Pricing, aggregation and summary contracts
remain official.

## Remaining compatibility / host patches

- Pi-only driver exposure; disabled native terminal, search and unsupported SDKs.
- Native supervisor management, loopback/tunnel transport isolation, browser
  authorization, private readiness and credential-safe subprocess environment.
- Managed tunnel health/publication diagnostics, not a second tunnel runtime.
- Desktop model visibility/preferences and config-change notifications.
- PiAdapterV2: six telemetry-only patches and two raster-image output projection
  patches; the optional `piMetrics` contract field has one patch. No Pi lifecycle,
  retry, steering, compaction or transport controls are replaced.
- PiProvider: two discovery-only patches capture raw context-window metadata for
  desktop model settings before the official wire projection drops it. Unknown
  defaults stay unknown; overridden effective windows are not labeled defaults.
- Review roots bounded to official active projects/worktrees because the host's
  configured cwd is its private state directory.
- First mobile message title compatibility for desktop drafts without titleSeed;
  actual title generation remains the official orchestrator's effect.
- Pi history and quota sources for stock mobile Usage/Limits, which upstream
  does not yet read from Pi sessions.

These are not permission to extend official provider behavior. On subsequent
upgrades, remove a compatibility patch once the corresponding upstream behavior
covers PiMac's requirement; do not transplant the old enhancement onto the new
implementation.

## Validation

For the build-109 upgrade: reproducible bundle check and all 88 Server tests
pass, including lazy tool retrieval and thread isolation. All 294 Swift tests
pass. The desktop fixture now asserts its reported Pi telemetry cost (`0.012`)
instead of the obsolete `cost == nil` expectation; missing-cost coverage remains
in the presentation tests. No running application or production state was
restarted/migrated during this upgrade.
Physical iPhone build-109 connection, sending, tool-detail expansion and
reconnection remain acceptance tasks.

```sh
./scripts/prepare-t3-server.sh
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
swift test
```

`upstream-maintenance.test.mjs` checks all manifest hashes and all patch anchors,
including modules not reached by the current bundle, and explicitly validates
the bounded telemetry/image/discovery exceptions while keeping Pi transport,
driver and lifecycle changes forbidden. Protocol fixtures exercise
native runs, persistence/restart, scheduler, attachments, model selection, Git,
DPoP, official scope denial and read-only scopes. They do not establish real-model,
public tunnel or App Store acceptance.
