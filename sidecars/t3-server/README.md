# Official T3 Server sidecar

Pinned upstream: `pingdotgg/t3code@8d846660cecfc69ef4e192322fced29fa07f374c`.
This uses upstream orchestrator V2 and its official `PiDriver`, `PiAdapterV2`,
and `PiRpc`, without modifying those implementations. The former custom Pi
adapter, transport, runtime controls, and their tests have been removed.

Pi Mac retains only host policy and management: loopback Server/administration,
a default-on LAN HTTP/WebSocket transport, explicit RPC/HTTP allowlists, supervisor
credentials, managed T3 Connect, diagnostics, and desktop model preferences.
LAN shares upstream authentication and the same environment identity; it never
publishes administration routes or introduces another orchestration engine. The supervisor has no workspace/Pi command API.
Provider subprocesses must not inherit supervisor secrets.

## Reproducible build

Commit host sources, patches, tests, dependency locks, and `upstream-pin.json`.
The manifest hashes 1,745 upstream files. `upstream/`, `node_modules/`,
`generated/` and the app's generated `vendor/t3-server.mjs` are build artifacts.
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

## Protocol / upgrade

Clients require orchestration protocol **2**. Project mutations and orchestration
commands use official Effect RPC; HTTP serves V2 shell/thread projections.
`settings-migration.mjs` backs up obsolete launch settings and converts only
legacy `binaryArgs`, removing old host-injected extensions. Upstream owns
SQLite and V1 transcript migration; do not reinterpret old private Pi cursors
as native file paths. Back up real Server state before first upgraded startup.

The desktop uses official runtime requests for extension dialogs and `/compact`
for compaction. Arbitrary tool output, full diffs and tool images are omitted
by upstream wire projection. Terminal-only extension status and old private
account/Fast/compaction-model overrides are not preserved.

See `docs/t3-server-migration.md` for capabilities, limitations and acceptance
boundaries, and `docs/t3-upstream-maintenance.md` for the upgrade and patch audit. Protocol-fixture tests do not prove real-model or App Store acceptance.
