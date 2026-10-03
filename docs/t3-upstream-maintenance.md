# T3 Code upstream maintenance

## Current upgrade

- Repository: https://github.com/pingdotgg/t3code, branch `main`.
- Previous pin: `cc1e634bfa62edd56ff792eea666e436fdef788f`.
- New pin: `8d846660cecfc69ef4e192322fced29fa07f374c`.
- SHA-256 manifest: 1,745 pristine upstream files, including newly added server
  modules. Generated caches and bundles are not source-controlled.
- Upstream Effect/platform dependencies remain `4.0.0-rc.115`; no dependency
  version override was needed. Orchestration protocol remains 2.

## Official implementations, not local enhancements

PiDriver, PiRpc, PiAdapterV2 and wire contracts are now unpatched. Removed the
local file-change detail/diff helper, tool-parent inference, output-usage helper,
assistant-duration wire field, and their helper-only tests. Native tool events,
file changes, token usage, steering, cancellation and settlement use official
projection semantics. Desktop tests cover flat Pi tool items and absent output
speed instead of depending on the deleted enhancements. If upstream supplies
`turnTokenUsage`, the desktop can use its official turn timestamps; it does not
inject missing usage.

Upstream now authorizes RPC scopes in connection-scoped group middleware. The
host's deny-by-default RPC allowlist and credential-free diagnostics supplement
that official middleware, including streaming methods. The retired per-handler
scope wrappers in `ws.ts` are no longer patched. Dynamic device-list checks and
HTTP authorization remain upstream-owned.

Provider model visibility follows the new config snapshot layout. Pi-only
mobile history integration preserves Pi dedupe keys with upstream's new
multi-file Codex deduplication path. Pricing, aggregation and summary contracts
remain official.

## Remaining compatibility / host patches

- Pi-only driver exposure; disabled native terminal, search and unsupported SDKs.
- Native supervisor management, loopback/tunnel authentication policy, browser
  authorization, private readiness and credential-safe subprocess environment.
- Managed tunnel health/publication diagnostics, not a second tunnel runtime.
- Desktop model visibility/preferences and config-change notifications.
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

```sh
./scripts/prepare-t3-server.sh
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
swift test
```

`upstream-maintenance.test.mjs` checks all manifest hashes and all patch anchors,
including modules not reached by the current bundle, and guards against adding
Pi adapter/transport/driver or contract patches again. Protocol fixtures exercise
native runs, persistence/restart, scheduler, attachments, model selection, Git,
DPoP, host-policy denial and read-only scopes. They do not establish real-model,
public tunnel or App Store acceptance.
