# account-usage

Pi Mac's companion extension, maintained in `extensions/account-usage/` in the same repository as the Swift app. Requires Pi **0.99.1+** for OpenAI ChatGPT support.

## Local development / installation

From the Pi Mac repository root:

```bash
npm --prefix extensions/account-usage ci --ignore-scripts
./scripts/link-account-usage.sh
```

The link points `~/.pi/agent/extensions/account-usage` at this directory. Existing unrelated installations are not overwritten. Restart Pi / reconnect Pi Mac sessions to load changes. Do not simultaneously load an old package installation of `account-usage`.

## Commands

- `/accounts`: manage accounts for the current model's provider, including logging in.
- `/accounts switch <name>`: explicitly switch the current session and future default.
- `/usage`, `/usage refresh`, `/usage settings`, `/usage history`, `/usage show`.

Select an **openai** model before logging in to a new OpenAI ChatGPT account; select **openai-codex** for legacy Codex. New OpenAI login uses Pi's native OAuth implementation, issued client ID, direct-token scope, and stable installation device ID. TUI uses Pi's native login components; RPC forwards links and prompts to the client.

### Provider isolation

| Data | Legacy Codex | New OpenAI ChatGPT |
| --- | --- | --- |
| OAuth accounts | `codex-accounts.json` | `openai-chatgpt-accounts.json` |
| Visibility | `codex-account-usage.json` | `openai-chatgpt-account-usage.json` |
| Warm-up claims/history | `codex-account-auto-warmup.json` | `openai-chatgpt-account-auto-warmup.json` |

All files remain under Pi's agent directory (`~/.pi/agent` by default), with owner-only permissions. **No credentials belong in this repository.** Names, defaults, refresh tokens, quota caches, and session bindings are isolated by provider. Existing legacy files and old session bindings remain compatible. Legacy tokens are never copied into the new OpenAI store: log in again to obtain the required OAuth grant.

An OpenAI API key (stored or environment/runtime) is not automatically replaced by managed subscription accounts. Explicit `/accounts switch` opts that session into managed ChatGPT auth; automatic rotation is enabled only when the extension reports managed auth. Account changes are rejected during active tasks. Old sessions retain their own provider-specific account binding.

Quota requests use the ChatGPT usage/reset-credit endpoints. A direct-token credential must include a usable ChatGPT account ID (credential metadata or token claims) and be authorized by those endpoints. Missing IDs, unsupported grants, or HTTP failures produce an account error, not invented quota or a fallback to another provider's credentials. **Live browser login and direct-token endpoint permissions require manual validation; mocked tests do not establish upstream authorization.**

## Refresh and warm-up behavior

Quota results are shared through owner-only caches, partitioned by provider. Active sessions refresh at most once per minute; idle sessions at most once every three minutes. `/usage refresh` bypasses the cache. Gemini quota display remains available through the `antigravity` provider.

The existing warm-up behavior is retained: a full, unused 5-hour or 7-day window may trigger a small `你好` request with `gpt-5.6-luna` at low reasoning, using the account's own provider. Window claims and the 10-minute cooldown are provider-specific. These requests can consume subscription quota. Hidden accounts are excluded.

Failures are recorded in the private `account-usage-errors.jsonl` diagnostic log, excluding credentials, headers, URLs, and response bodies.

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

`activeAccount` is omitted when the session uses unmanaged auth, including an API key. Pi Mac retains version-1 legacy support and keeps quota snapshots separate by provider. TUI uses `account-usage` for human-readable status.

## Validation

```bash
npm --prefix extensions/account-usage test
npm --prefix extensions/account-usage run prepublishOnly
node scripts/test-pi-compatibility.mjs
```

Tests use temporary agent directories and synthetic credentials; they do not access real accounts or invoke paid models. Full project validation: `./scripts/check.sh`.

Pi 0.99.1's coding-agent npm package bundles `brace-expansion@5.0.9`, which `npm audit` flags for a high-severity denial-of-service issue. It is an upstream bundled dependency: `npm audit fix` cannot replace it. The lockfile preserves Pi 0.99.1; recheck the audit when upgrading Pi rather than silently modifying host package internals.

MIT licensed. Extensions run with the user's OS permissions; review source before loading.
