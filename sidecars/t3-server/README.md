# Pi Mac native T3 Server adapter

The pinned upstream Server is the sole orchestration engine for desktop, iOS and
Telegram. It owns projects, threads, receipts, persistence, projections and
reactors. `pi-provider.mjs` owns Pi runtimes through private `pi-rpc.mjs` transport.
There is no architecture switch, desktop projection or desktop command IPC.

See [architecture and current limits](../../docs/t3-server-migration.md) and
[iOS integration](../../docs/t3-code-integration.md).

## Source and artifacts

Commit host/adapter sources, `patches.json`, fetch/build scripts, tests, locked
npm dependencies and `upstream-pin.json`. Preserve the shipped
`vendor/T3-SERVER-LICENSE.txt` notice.

Do not commit generated dependencies/artifacts:

- `upstream/`: 673 unchanged files restored from the pinned Git revision and
  individually SHA-256 verified.
- `node_modules/`: installed with `npm ci --ignore-scripts`.
- `generated/`: test client/provider harness bundles.
- `Sources/PiMacApp/Resources/t3-bridge/vendor/t3-server.mjs`: generated app bundle.

Patches are applied in memory; the cached upstream sources remain unchanged.
They register Pi and enforce host capabilities/network policy, not replace the
native orchestration engine. The historical `sidecars/t3-rpc` subset is no longer
installed, bundled or checked by the application build pipeline.

## Clean build

Requires Node.js 24+, npm, Git and tar:

```sh
./scripts/prepare-t3-server.sh
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
swift test
```

Preparation installs this sidecar's locked dependencies, restores pinned source
and generates the resource. Packaging/CI run it before Swift compilation. It
never launches Pi or the app; installed applications do not download source/npm.

For offline upstream restoration from a checkout containing the pinned commit:

```sh
node sidecars/t3-server/fetch-upstream.mjs --source /path/to/t3code
```

A valid cache needs no source download. A modified cache fails rather than being
silently overwritten; move it aside explicitly before recreating it.

## Verification scope

The reduced suite focuses on native command/receipt/projection persistence,
continuation, model changes/cancellation, sole runtime ownership, settlement,
bounded RPC unknown outcomes, provider isolation and loopback OAuth policy.
Tests use protocol-only Pi fixtures, not real models or credentials.
Actual Pi account/model behavior and physical iPhone/Apple/APNs acceptance remain
separate manual checks.
