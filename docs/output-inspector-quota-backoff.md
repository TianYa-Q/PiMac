# Output inspector, cancellation boundaries and quota backoff

## Native output reading

- Textual tool detail surfaces now provide an enlarged reader with the same literal search, head/tail preview, wrapping, copy and export controls. Closing the reader does not close the conversation. The reader reuses `ToolDetailView` and native TextKit rather than maintaining a second parsing/rendering path.
- Search highlights every retained match with temporary layout attributes. Navigating still selects the current match. Highlights neither mutate text storage nor change clipboard/export contents or manual selection on unrelated updates. Range validation uses subtraction to avoid overflow; highlighting retains the existing 1,000-match cap.
- Tail mode offers an explicit follow/pause control. With follow enabled, new output and layout changes scroll to the bottom; a selected search match temporarily takes precedence. Disable follow to read older output without jumping back to the end.
- Rendering remains bounded to 128 KiB / 2,000 lines in both inline and enlarged readers. The enlarged reader is not a full-transcript renderer; search covers its preview, while copy/export retain the original text. This does not restore private rich-output fields absent from the official Server projection.

## Scheduled task cancellation

- Already-cancelled refresh/save/actions never call the transport, even if that transport ignores task cancellation.
- Cancelling read-only preflight exits without dispatching a modification or creating an unknown-mutation barrier. Cancellation is checked again immediately before dispatch.
- Cancellation after dispatch is still ambiguous: preserve the refresh barrier, keep authoritative rows, and never automatically retry a mutation that the Server may have accepted.
- Server-side concurrent-edit policy and RPC schemas are unchanged.

## Extension quota behavior

- `/usage cached` displays only the current session's identity-matched, visible OpenAI/Codex snapshots. It does not invoke quota requests, OAuth activation, account rotation or warm-up. Empty/replaced-identity snapshots report a clear recovery command. Ages remain visible; ordinary background refresh is not paused. It does not read another process's shared cache or include Gemini snapshots.
- Transient GET retries now honor `Retry-After` delta seconds and IMF-fixdate HTTP dates, with a minimum 250 ms backoff. Invalid values use the existing minimum. If the server-requested delay cannot fit the remaining monotonic request budget, return the HTTP error rather than shorten the server's wait or send another request.
- Retry budget remains one for network failures and HTTP 502/503/504. Authentication errors, 429, malformed JSON and OAuth refreshes remain non-retryable. Redirect, response-size, cancellation and total-deadline policies are unchanged.
- Retry policy is extracted into a pure module for deterministic boundary tests. No dependencies, persisted formats or credentials require migration.

## Validation

`./scripts/check.sh` covers formatting, Swift tests, extension typechecking/lint/tests, Python watcher tests, fast extension checks, installed Pi RPC/codemode compatibility, and Server check/tests. Regression tests include temporary-vs-persistent highlights, invalid/overflowing ranges, follow/pause layout behavior, cancelled preflight/dispatch boundaries, offline cached commands with replaced identities, HTTP backoff and cleanup.

Tests use synthetic credentials and local fixtures. Live OAuth permissions, real service throttling, and visual interaction in a running macOS window still require manual acceptance.
