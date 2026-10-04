# PiMac / account-usage optimization round

## Reliability and refactoring

- Extracted ordered bounded workers into `extensions/account-usage/concurrency.ts`. They validate limits, stop dequeuing after cancellation/failure, and await active workers before returning. Cache leases therefore cannot be released while their batch still runs. Quota requests and automatic warm-ups both use two workers.
- Provider refreshes now settle independently. Successful quota state is published even if another provider's cache fails. An obsolete refresh cannot publish, rotate accounts inside that refresh, or replace the current refresh timer.
- Overlapping automatic Gemini refreshes share an in-flight promise. Its freshness timestamp advances only after success, not before network/cache work begins. Manual forced refreshes still bypass freshness checks.
- HTTP readers use geometrically grown byte storage instead of retaining every network chunk. Received-byte limits, fatal UTF-8 decoding, reader cleanup, total deadlines and redirect policy are preserved. Invalid byte limits are rejected before transmitting credentials.

## Native diff UI

- `GitDiffPresentation` separates bounded parsing, line classification, preview statistics and search from SwiftUI. Parsing runs outside the main actor; request identity is checked again before publishing its result.
- Git previews include original diff-text line numbers, addition/deletion colors, search (Command-F), change-only filtering, counts, empty-search feedback and refresh. The Server connection is observed so retry controls update when connectivity changes.
- At most 10,000 lines are rendered with a lazy stack, in addition to the existing 2 MiB text bound. Statistics and search refer to rendered lines. Copy preserves all text in the byte-bounded preview, including lines not rendered; the UI explains both limits.
- File headers are distinguished from header-like additions/deletions inside hunks. LF/CRLF, Unicode, blank lines, multiple files and exact limits are covered by regression tests.

## Validation

Run `./scripts/check.sh` for Swift formatting/tests, extension types/lint/format/tests, fast extension and real Pi RPC/codemode compatibility, and Server checks/tests. Tests use synthetic credentials; they do not validate live OAuth grants, paid model calls, or visual interaction in a running macOS app.

No persisted account/cache format, RPC schema, credential storage policy, dependency version, or upstream Server implementation was changed. Existing local data requires no migration.
