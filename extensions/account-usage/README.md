# account-usage

Pi Mac's companion extension, maintained in `extensions/account-usage/` in the same repository as the Swift app. Requires Pi **0.99.1+** for OpenAI ChatGPT support; development dependencies and compatibility tests now target **Pi 1.0.0**.

## Local development / installation

From the Pi Mac repository root:

```bash
npm --prefix extensions/account-usage ci --ignore-scripts
./scripts/link-account-usage.sh
```

The link points `~/.pi/agent/extensions/account-usage` at this directory. Existing unrelated installations are not overwritten. Restart Pi / reconnect Pi Mac sessions to load changes. Do not simultaneously load an old package installation of `account-usage`.

## Commands

- `/accounts`: manage accounts for the current model's provider, including logging in. The Health Check menu action runs the same read-only report as `/usage doctor`; it performs no network requests or account switching.
- `/accounts switch <name>`: explicitly switch the current session and future default.
- `/usage`, `/usage refresh`, `/usage settings`, `/usage history`, `/usage show`.
- `/usage doctor json`: version-2 count-only JSON health report via the notification channel (provider/auth state, account/snapshot counts, refresh and Gemini status, `healthy` / `attention` / `degraded` summary and stable recommendation codes). No account names/IDs/errors, network requests or state changes. Headless clients may ignore notifications.
- `/usage doctor`: read-only health report for auth ownership, visible/hidden account counts, fresh/stale/failed/unknown quota snapshots, refresh activity and Gemini snapshot state. It does not query the network, warm up models or switch accounts, and never prints credentials, account IDs or raw provider errors. Snapshot health is not a live connectivity test.

Select an **openai** model before logging in to a new OpenAI ChatGPT account; select **openai-codex** for legacy Codex. New OpenAI login uses Pi's native OAuth implementation, issued client ID, direct-token scope, and stable installation device ID. TUI uses Pi's native login components; RPC forwards links and prompts to the client.

### Provider isolation

| Data | Legacy Codex | New OpenAI ChatGPT |
| --- | --- | --- |
| OAuth accounts | `codex-accounts.json` | `openai-chatgpt-accounts.json` |
| Visibility | `codex-account-usage.json` | `openai-chatgpt-account-usage.json` |
| Warm-up claims/history | `codex-account-auto-warmup.json` | `openai-chatgpt-account-auto-warmup.json` |

All files remain under Pi's agent directory (`~/.pi/agent` by default), with owner-only permissions. **No credentials belong in this repository.** Names, defaults, refresh tokens, quota caches, and session bindings are isolated by provider. Existing legacy files and old session bindings remain compatible. Legacy tokens are never copied into the new OpenAI store: log in again to obtain the required OAuth grant.

Account, visibility and warm-up JSON documents are limited to 4 MiB (on both reads and writes). Reads reject symlinks, special files and invalid UTF-8; FIFO paths cannot block Pi. Writes flush a private temporary file and atomically replace the document, cleaning up failed writes. Valid names including `__proto__`, `constructor` and `toString` are handled as ordinary keys. Oversized/corrupt documents fail closed without deleting credentials; back them up before repair. Existing formats are unchanged. See [storage and native dialog hardening](../../docs/extension-dialog-storage-hardening.md).

An OpenAI API key (stored or environment/runtime) is not automatically replaced by managed subscription accounts. Explicit `/accounts switch` opts that session into managed ChatGPT auth; automatic rotation is enabled only when the extension reports managed auth. Manual account changes are rejected during active tasks. Pending account menus, selection, login and visibility dialogs are bound to their originating store and session cancellation owner; responses after shutdown/restart or provider replacement are rejected instead of applying to the new context. Automatic changes use Pi's awaited safe boundaries (see below). Old sessions retain their own provider-specific account binding.

Quota requests use the ChatGPT usage/reset-credit endpoints. Both response bodies are read incrementally with a 64 KiB limit on received bytes, even without a reliable Content-Length header. Oversized/error bodies are cancelled rather than drained into memory; cancellation releases stream readers. Request timeouts are distinguished from user cancellation. A direct-token credential must include a usable ChatGPT account ID (credential metadata or token claims) and be authorized by those endpoints. Missing IDs, unsupported grants, or HTTP failures produce an account error, not invented quota or a fallback to another provider's credentials. **Live browser login and direct-token endpoint permissions require manual validation; mocked tests do not establish upstream authorization.**

Usage GETs retry transient network failures and HTTP 502/503/504 at most once after 250 ms, within the 15-second total query budget. Authentication failures, HTTP 429, malformed responses and OAuth refreshes are not automatically retried. The supplementary reset-credit endpoint has a separate 3-second ceiling and no retries: its failure does not hide valid usage windows. Requests require HTTPS without embedded URL credentials and never follow redirects with credentials. Invalid timer sizes and retry budgets fail before making a request. The caller's wait is also bounded when a custom transport ignores AbortSignal; late headers are cancelled and cannot trigger retries or publish results. Actual I/O cleanup still depends on transport cancellation support.

## Gemini snapshot reliability

Gemini snapshots carry their original `capturedAt` time through the shared cache and RPC status. Re-publishing a cached snapshot does not make it fresh. TUI warns on stale, future or unknown sample times, using the active (60 seconds) / idle (180 seconds) cadence. Old snapshots without a timestamp remain readable but show unknown age.

Credential lookup and the Antigravity adapter share a 15-second wait deadline. Session cancellation immediately ends the wait; late results and failures cannot replace current state. The upstream adapter does not accept an AbortSignal, so timeout bounds the extension's wait, **not necessarily the underlying network request**. No new automatic retries are introduced.

## Automatic rotation and weekly balancing

Both policies run **inside this Pi extension**, in TUI/RPC/headless sessions;
Pi Mac only displays status and submits manual commands. No desktop UI is required.
They apply only to extension-managed `openai` / `openai-codex` OAuth bindings,
never unmanaged API keys, other providers or virtual models.

- **Low quota:** a 5-hour window below 5% (or a weekly window at/below 5%)
  selects an eligible account with more than 5% short-window quota and, when
  reported, more than 5% weekly quota. Hidden, failed, stale and unknown
  short-window quotas are excluded. With no eligible account nothing changes.
- **Weekly balance:** rank accounts by sustainable remaining percent/day until
  weekly reset, reserving 5 points and using a six-hour minimum divisor.
  Prefer accounts not more than 15 points ahead of linear weekly consumption.
  Rebalance only when the active account is ahead of that consumption pace or
  the best paced account's daily budget exceeds the active budget by 1.5x.
  Unknown weekly quota retains a deterministic name-order fallback for urgency
  only; it does not trigger balancing. Successful rotation and explicit manual
  selection suppress balancing for ten minutes; low-quota switching bypasses
  this cooldown.

Timer refreshes can rotate only while idle. Before a user run, both policies
can select an account; between completed turns (after tools finish), only
low-quota rotation applies. No live request/tool is aborted and no prompt is
replayed. At final pre-settlement, a recognized quota/rate-limit failure forces
fresh telemetry and may request **one** continuation after a successful urgent
switch. Cancellation, unrelated failures and failed switching do not auto-retry.
Automatic selection persists only the current session binding, not the global
future-session default or other live sessions. Manual `/accounts switch` still
updates the default. Failed activation restores the prior account when possible;
if restoration fails, the existing auth-failure guard prevents the next turn.

The policy is in `rotation.ts`; lifecycle and credential application are in
`index.ts` / `auth.ts`. Tests use synthetic credentials and mocked quota endpoints,
not live paid requests. Live quota exhaustion/continuation still needs validation.

## Refresh and warm-up behavior

TUI quota summaries include actual sample age; status segments warn on stale, unknown or future sample times (60 seconds while active, 180 seconds while idle). Missing usage windows display an explicit unknown quota rather than a blank field. The shared freshness policy also drives the read-only health report. Version-2 diagnostics add ordered recovery suggestions for authentication, account visibility and quota refresh; active refreshes suppress redundant refresh advice. Healthy cached data is not proof of live connectivity.

HTTP cancellation starts cleanup and releases reader locks without awaiting an untrusted underlying source's cancellation promise. Hanging source cleanup cannot stall an error, retry or session cancellation. Concurrent queries preserve the earliest observed worker failure (not input order), while still draining active workers before releasing leases.

Quota results are shared through owner-only caches, partitioned by provider. Cache keys digest provider, account name and stable ChatGPT account ID (or conservatively the opaque access grant), so a same-name replacement login cannot inherit another account's quota. Token refreshes retain cache identity when an account ID is available. IDs and tokens are never persisted in cache keys. Identity is checked again after querying and before status publication or automatic rotation; mismatches discard local telemetry until refreshed. Older name-only entries are treated as misses without migrating credentials. Queries for the same provider coalesce behind a hashed namespace lock; unrelated providers query concurrently, so a slow Gemini endpoint no longer holds up Codex/OpenAI refreshes. A short document lock merges each result into the latest snapshot to avoid lost updates. The existing cache format and global document lock remain compatible with older processes (older versions may still hold that lock during network I/O). Active sessions refresh at most once per minute; idle sessions at most once every three minutes. `/usage refresh` bypasses snapshots that existed when the command started. Overlapping forced refreshes can share a newly published, identity-matched snapshot; sequential forced refreshes still query again. Publication revisions are optional in the version-1 cache format, so older snapshots remain readable. The shared document is bounded to 1 MiB: under capacity pressure, oldest other-provider snapshots are evicted first; an oversized new snapshot is rejected without altering the previous file. Waiting for another process's cache lock is cancellable; cancelled or failed queries never replace the previous snapshot. Future-dated snapshots are re-queried after clock changes. Gemini quota display remains available through the `antigravity` provider.

The existing warm-up behavior is retained: a full, unused 5-hour or 7-day window may trigger a small `你好` request with `gpt-5.6-luna` at low reasoning, using the account's own provider. Window claims and the 10-minute cooldown are provider-specific. These requests can consume subscription quota. Hidden accounts are excluded.

Account queries and warm-ups run with at most two workers. Cancellation or a failed worker stops queued work and drains active workers before releasing shared-cache leases. Refreshes await both providers and publish successful results even when the other provider fails; obsolete refreshes cannot publish or reschedule timers. Overlapping automatic Gemini refreshes await the same in-flight query. Failed Gemini queries do not start a freshness cooldown. Incremental HTTP storage grows geometrically rather than retaining one object per received chunk.

Failures are recorded in the private `account-usage-errors.jsonl` diagnostic log, excluding credentials, headers, URLs, and response bodies. Error names, transport codes and syscall metadata use finite allowlists; unknown values are omitted, and recursive/aggregate errors are bounded. Account-name context is retained in this private log, not in the JSON health report. HTTP read failures preserve the caller's cancellation or deadline when a transport returns a generic network error during abort.

## RPC protocol

`account-usage-gui` publishes version **2** structured status:

```json
{
  "version": 2,
  "provider": "openai",
  "supportsAccountSwitch": true,
  "managesSelectedAuth": true,
  "activeAccount": "work",
  "defaultAccount": "work",
  "updatedAt": 0,
  "accounts": [],
  "gemini": { "kind": "unconfigured", "isActive": false, "quotas": [] }
}
```

Each account can include `capturedAt` (Unix milliseconds), the provider query time. `updatedAt` is the status publication time, not proof of fresh quota. Pi Mac displays sample age separately, marks samples stale at 60 seconds while busy / 180 seconds while idle, and warns about samples more than five seconds in the future. Legacy samples without timestamps display an unknown-age label. It rejects oversized status JSON (over 1 MiB), malformed numeric fields and duplicate row identities before rendering.

`activeAccount` is omitted when the session uses unmanaged auth, including an API key. Pi Mac retains version-1 legacy support and keeps quota snapshots separate by provider. TUI uses `account-usage` for human-readable status.

## Validation

```bash
npm --prefix extensions/account-usage test
npm --prefix extensions/account-usage run prepublishOnly
node scripts/test-pi-compatibility.mjs
```

Tests use temporary agent directories and synthetic credentials; they do not access real accounts or invoke paid models. Full project validation: `./scripts/check.sh`.

Pi 1.0.0's coding-agent npm package still bundles `brace-expansion@5.0.9`, which `npm audit` flags for a high-severity denial-of-service issue. It is an upstream bundled dependency: `npm audit fix` cannot replace it. The lockfile now targets Pi 1.0.0; recheck the audit when upgrading Pi rather than silently modifying host package internals.

MIT licensed. Extensions run with the user's OS permissions; review source before loading.
