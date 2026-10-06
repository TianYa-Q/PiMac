# Official T3 Server sidecar

Pinned upstream: `pingdotgg/t3code@442735897f6f92af33798075baa12d4fd4d710dd`.
This uses upstream orchestrator V2 and its official `PiDriver`, `PiAdapterV2`,
and `PiRpc`. A telemetry-only PiAdapter patch records per-message usage and
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
Lifecycle remains upstream-owned.
The former custom Pi
adapter, transport, runtime controls, and their tests have been removed.

Pi Mac retains only host policy and management: loopback Server/administration,
a default-on LAN HTTP/WebSocket transport, explicit RPC/HTTP allowlists, supervisor
credentials, managed T3 Connect, diagnostics, and desktop model preferences.
LAN shares upstream authentication and the same environment identity; it never
publishes administration routes or introduces another orchestration engine. The supervisor has no workspace/Pi command API.
Provider subprocesses must not inherit supervisor secrets.

## Reproducible build

Commit host sources, patches, tests, dependency locks, and `upstream-pin.json`.
The manifest hashes 1,798 upstream files. Effect and its Node platform packages
are pinned together at `4.0.1`. `upstream/`, `node_modules/`,
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

Target mobile client: T3 iOS build **109** (physical-device acceptance pending).
The EAS build number is remotely managed, not a Server version or a verified
mapping to this commit. Clients require orchestration protocol **2**.
The host explicitly allows `orchestration.getTurnItem` for upstream's lazy
full-tool-detail fetch, retaining official read scope and thread/item isolation. Project mutations and orchestration
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
