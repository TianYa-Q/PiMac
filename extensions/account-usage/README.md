# Account session adapter

PiMac now owns account management and quota monitoring. This extension is only the **Pi session execution adapter**; it does not start background quota requests, send activation messages, or present account-management menus.

## Ownership

| PiMac host (runs while PiMac is open) | Pi extension (requires a session) |
| --- | --- |
| Official OAuth login for managed ChatGPT/Codex accounts; default account; delete; visibility | Apply and restore session-local runtime credentials without replacing API keys |
| Quota queries, in-memory cache, identity-matched disk snapshots | Restore the saved session account; respect provider isolation |
| Fixed one-minute background checks, startup/wake catch-up | Safe account rotation at idle/pre-run/turn boundaries |
| Activation with `你好`, durable claims, cooldown and retry | At most one continuation after a confirmed quota error and successful switch |
| History, health summary, sanitized decision log | `/accounts switch <name>` changes only the current session |

Open **PiMac → account quota card → account management** to log in or change defaults. A Pi conversation is not required. The host loads the installed Pi's official OAuth/provider implementation, including npm symlinks and pnpm shims; it does not maintain another OAuth implementation or copy a legacy grant into the newer OpenAI store. Global `auth.json` remains owned by Pi; API keys are not overwritten. Native-only expired credentials still require renewal through their owning Pi provider.

The old Pi `/usage` command and `/accounts` management menu have been removed. Telegram's `/usage` command is separate and remains available.

## Session adapter installation

```sh
npm --prefix extensions/account-usage ci --ignore-scripts
./scripts/link-account-usage.sh
```

Remove duplicate old installations. Existing Pi runtimes must safely reopen/reload the extension before they adopt the new session-only behavior; never interrupt active tasks to force this.

## Storage and diagnostics

All private data remains in `~/.pi/agent` (or `PI_CODING_AGENT_DIR`), never in the repository:

- `codex-accounts.json` / `openai-chatgpt-accounts.json`: separate credentials and future-session defaults.
- `codex-account-usage.json` / `openai-chatgpt-account-usage.json`: visibility settings.
- `codex-account-auto-warmup.json` / `openai-chatgpt-account-auto-warmup.json`: durable claims and the latest 100 activation results.
- `pimac-openai-codex-quota.json` / `pimac-openai-quota.json`: validated, identity-matched host telemetry for safe session rotation. Missing files mean unknown, corrupt files produce an explicit warning, and same-name replacement logins cannot inherit old telemetry.
- `pimac-account-monitor.jsonl`: bounded, owner-only monitoring log, rotated at 1 MiB. Includes sample failures, per-window sample values and activation eligibility/skip/result reasons. It never logs access tokens, refresh tokens, request bodies or raw provider errors.
- `account-usage-errors.jsonl`: session-auth diagnostics, including `read_state`, `initialize`, `activate` and `block_run` stages.

## Activation policy

Activation only uses successful, fresh samples from visible managed accounts. A full 5-hour / 7-day window with a reset time near the complete duration is eligible; an expired full window is also eligible for recovery. Full quota with an already-running shorter countdown is not sufficient to send another message. Missing/unknown windows and failed/stale queries never trigger activation.

Two eligible windows for one account share one `gpt-5.6-luna` low-reasoning request. At most two accounts run concurrently. Durable claims prevent overlapping requests; successes have a ten-minute cooldown. A failed claim can retry after its two-minute lease even if the reset timestamp has not changed. Claims use private account-identity digests, so aliases coalesce and replacement logins do not inherit another account's success.

A successful response means **the request succeeded**, not that a server countdown was proven to start. These real requests can consume subscription quota. Closing PiMac cancels host work; viewing/switching conversations never owns the monitoring lifecycle.

## Development

```sh
npm --prefix extensions/account-usage run typecheck
npm --prefix extensions/account-usage run lint
npm --prefix extensions/account-usage test
cd sidecars/t3-server
node --import tsx --test tests/account-runtime.test.ts tests/pi-account-management.test.mjs
```

Host implementation: [`account-runtime.ts`](../../sidecars/t3-server/account-runtime.ts). The extension directory also contains the shared private-storage, identity and policy library used by the host; those modules do not start an extension runtime.
