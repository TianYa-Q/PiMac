# Pi Mac T3 RPC runtime

Private build workspace for the bundled Node WebSocket/Effect RPC adapter, not a
standalone agent, T3 orchestration engine or Pi extension.

- Pinned `effect@4.0.0-rc.115`, `ws@8.22.0`, build-only `esbuild@0.28.2`.
- Baseline: `pingdotgg/t3code` commit `a97a4a9d189f145afe79c3a6f8533bbf9a6b40b1`.
- `runtime.mjs`, `read-schemas.mjs`, `workspace.mjs`, `config.mjs`: authenticated
  probe/config/settings/lifecycle and historical/live shell/thread subscriptions.
- `commands.mjs`: bounded text/inline-image command validation and reconnect
  deduplication; native consent, identity and readiness guards own actual sends.
- `upstream/`: unchanged original contract closure with `upstream-pin.json`
  SHA-256 verification. Contracts only, not provider or session services.
- `test-client.mjs`, `generated/upstream-validation.mjs`: real Effect client and
  independent full-contract validation fixture, excluded from the app bundle.

```sh
npm --prefix sidecars/t3-rpc ci --ignore-scripts
npm --prefix sidecars/t3-rpc run build
npm --prefix sidecars/t3-rpc run check
node --test Tests/T3Bridge/*.test.mjs
```

Commit sources, pins, lockfile and generated artifacts together. The installed
application ships only resources under `Sources/PiMacApp/Resources/t3-bridge/`,
including the generated runtime (~442 KiB) and licenses; it performs no npm
install/download. T3's MIT notice is retained there and under `upstream/`.

The reviewed Effect patch changes client hooks, MCP deletion and browser HTTP
fallback, not this server's JSON framing. It is not required by this subset.
Original source-schema and real Effect client tests do **not** establish actual
App Store client compatibility; that needs physical iPhone verification.

Device authorization lives outside the dependency bundle. A socket is bound to
one ticket-authenticated session. RPC headers cannot change that identity;
unsupported commands never dispatch workspace mutations. Config has no fake
Codex/Claude provider; existing-thread sends use the shared native Pi runtime.

See `docs/t3-code-integration.md` for settings, network warnings, budgets, crash
ownership/recovery and remaining work. Public and private listeners are separate;
network exposure and mobile sending each require explicit, default-off consent.
