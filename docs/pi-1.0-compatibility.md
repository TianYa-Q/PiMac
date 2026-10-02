# Pi 1.0 and Code Mode compatibility

Compatibility baseline: `@earendil-works/pi-coding-agent@1.0.0` (npm `latest` checked
on 2026-10-02). Runtime requirement: Node.js 22.19+. Local validation used Node
24.14.1. The companion extension's development dependencies/lockfile target Pi
AI, coding-agent and TUI 1.0.0; its existing 0.99.1+ peer range remains unchanged.

## Enable Code Mode

Pi Mac continues using the official JSONL RPC CLI and inherits Pi settings.
It does not replace tools with a hardcoded `--tools` list or install a substitute
for Pi's built-in codemode extension.

```sh
node scripts/enable-codemode.mjs
```

The helper edits the configured agent directory's `settings.json` (normally
`~/.pi/agent/settings.json`), creates a private backup, and atomically replaces
only the settings file. It preserves models, packages, MCP-related configuration,
explicit tool selections and Code Mode options. Invalid JSON/schema or a symlink
is rejected rather than overwritten; pass the symlink target explicitly.

For ordinary defaults, the resulting settings contain:

```json
{
  "defaultTools": ["+codemode"],
  "codemode": {"mode": "on"}
}
```

`on` keeps ordinary tool declarations available, while allowing the model to use
scripts. Existing `only` settings are preserved, not forced onto other users.
An explicit tool allowlist stays an allowlist; an empty one is not silently
expanded to read/bash/edit/write. Trusted project settings may still override
selection, and intentionally disabled built-in extensions remain disabled.
The model can choose scripts; enabling codemode does not require every operation
to use it. Script tool calls retain Pi's normal execution permissions.

Restart or reconnect **idle** sessions to load the upgraded executable and new
selection. Existing running processes are not terminated by this migration.

## Native transcript changes

- Codemode `{code: string}` and raw script inputs render as JavaScript, not a JSON
  escaped string. Collapsed headers show at most three lines; expanding reveals
  the full script alongside its output and nested calls.
- Nested tool events retain their parent, and bounded `nestedCalls` metadata
  restores on history reload. Nested results do not become duplicate root rows.
- Tool-result image blocks, including `models.generateImages()` output, are
  cached by content digest as local attachments and displayed in expanded tool
  results. Base64 bytes do not become transcript text.
- Script failures keep partial output and a visible failure indicator.
- Existing usage aggregation counts codemode's model work. The integration test
  verifies image-model usage appears once in session totals.

This adds Mac transcript display for tool images, not automatic delivery of every
generated image through Telegram. Telegram's existing explicit file-link delivery
behavior is unchanged.

## Validation

```sh
./scripts/check.sh
```

The real installed-Pi smoke test uses a temporary agent directory and a synthetic
chat/image provider, not live credentials or a paid model. It exercises the
actual QuickJS sandbox and RPC/event pipeline:

- default tool selection with `+codemode`;
- parallel real `read` and `bash` calls with parent IDs;
- successful `store()`/`load()` state;
- the Pi 1.0 `models.generateImages()` API with synthetic image output and usage;
- partial output and script errors;
- `abort` during a running nested bash call;
- Fast commands, handled prompt/steer/follow-up, and account-usage status.

Swift tests cover script/history restoration, live tool images and failure
rendering. Companion tests/typecheck cover provider-isolated credentials and
quota operations. Config migration tests check backup/idempotence and preservation.

### Current working-tree checks

133 Swift Testing tests, 10 companion tests, 37 Node config/T3 tests, the real
installed-Pi Code Mode smoke test and companion typecheck/lint/format checks
passed. Targeted Swift formatting checks for this migration also passed.

The full `scripts/check.sh` currently stops at pre-existing formatting failures
in the uncommitted Telegram test files (for example
`TelegramQueuePresentationTests.swift` and `TelegramUsagePresentationTests.swift`).
Those unrelated changes were preserved; a fully green aggregate check is not
claimed. An unfiltered `swift test` can also hang when launching the legacy
Telegram XCTest bundle. `swift test --disable-xctest` validates the 133 Swift
Testing cases only; it must not be reported as validation of those XCTest cases.

## Known upstream dependency warning

The Pi 1.0.0 npm package bundles `brace-expansion@5.0.9`; `npm audit` reports a
high-severity denial-of-service issue. A safe `npm audit fix` cannot replace that
bundled dependency. This upgrade does not modify upstream package internals or
claim a clean audit; it needs an upstream fixed release. See the companion README.
