# Connection and quota hardening

This round includes the existing LAN implementation and its remembered automatic-start policy, plus desktop and extension reliability improvements.

## Desktop and transport

- LAN settings distinguish confirmed listener state from unknown request outcomes. A failed mutation reads the actual supervisor state; failed reconciliation blocks further mutations and pairing until **刷新入口状态** succeeds. A lost response is never reported as proof that the listener closed.
- Saved LAN startup work is bound to its Server generation, so delayed work cannot configure a replacement process.
- LAN proxies strip hop-by-hop headers, including headers nominated by `Connection`, as well as forwarding and host-control headers. HTTP upload/download bodies remain streamed. WebSocket upgrade headers are negotiated explicitly.
- Concurrent LAN shutdown callers share a completion barrier; disabling/shutdown closes even stalled WebSocket handshakes. Failed rebinding retains the existing listener.
- Settings add interface rescanning, empty-interface guidance, listener-state badges and copyable status feedback. Pairing QR images are cached rather than regenerated every second; expiry updates independently, hides expired credentials and rechecks validity before copying.
- Device management shows both connected and offline authorized devices. Revoking a specific stable session ID requires confirmation; a delayed result cannot update a replacement Server's device list.

LAN currently defaults on for an eligible physical private-IPv4 interface; explicit disable survives restart. It is **unencrypted HTTP**, not an Internet-facing endpoint. Do not forward the port publicly. Closing LAN is not device revocation; revoke grants separately. The official Server and supervisor stay loopback-only. App Store pairing, LAN/Tunnel catalog behavior and notifications still need physical-device acceptance.

## Companion extension

- Quota GET deadlines now bound the caller even when a custom fetch ignores cancellation. Late headers are cleaned up and cannot start retries or publish results; underlying I/O still relies on transport cancellation support.
- `/usage doctor` adds a concise health summary and ordered recovery suggestions. `/usage doctor json` moves to schema version **2**, retaining existing count-only fields and adding `status` and `recommendations`.
- Status values: `healthy`, `attention`, `degraded`. Recommendation codes: `repair_auth`, `review_visibility`, `add_account`, `refresh_usage`. Active refreshes suppress redundant refresh recommendations, but not auth repairs.
- Diagnostics remain read-only and contain no account names, IDs, credentials or provider error text. A healthy cached snapshot is not a live connectivity check. No additional quota requests, warm-ups or automatic account switches are introduced.

## Validation

Run `./scripts/check.sh` for Swift formatting/tests, watcher tests, extension type/lint/format/tests, Pi compatibility and Server generation/transport tests. New tests cover caller deadlines, cancellation with late headers, diagnostic recovery priorities, pairing expiry boundaries, proxy header sanitation, chunked bodies and stalled-upgrade shutdown.
