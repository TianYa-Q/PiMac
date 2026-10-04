# Native extension dialogs and account storage hardening

## PiMac features and UI

- Extracted extension dialogs out of `ContentView.swift` into `ExtensionDialogView.swift`. Pure option filtering, presentation identity and input budgets live in `ExtensionDialogPresentation.swift`.
- Generic selection dialogs with more than eight options now offer literal, case/diacritic-insensitive multi-word search, a result count and empty-state feedback. Return selects only when exactly one result remains. Original option strings, order and duplicate labels are preserved.
- All dialogs show their originating project/session and the number of other waiting requests. Long lists use lazy rendering; confirmation messages scroll; single-line input supports Return and input/editor prefills are initialized per presentation.
- Confirmation buttons intentionally do not acquire a Return shortcut: a permission/destructive confirmation must remain an explicit choice. Existing specialized account-management and visibility dialogs are preserved.

## Lifecycle safety and limits

- Every dialog has a local UUID independent of its wire request ID. SwiftUI sheet identity uses this UUID, including when different processes reuse the same RPC ID. Replacing a dialog resets local editor/search/focus state.
- Responses must include that presentation UUID. A delayed click or callback from an expired, closed or answered dialog cannot answer the next dialog. RPC responses continue using the original request ID and source.
- The application retains at most 64 requests, each with at most 256 KiB of combined UTF-8 title/options/message/input/placeholder data and 4,096 options. Overflow requests are answered as cancelled, never silently truncated or auto-approved. Duplicate resends do not consume capacity.
- Expiration reconciliation and source removal update the queue count even when they remove only queued requests. The server remains responsible for timeout expiry; the desktop does not invent a second timeout.

## account-usage stability and refactoring

- Account and warm-up timestamp maps now use null-prototype dictionaries. Valid names such as `__proto__`, `constructor` and `toString` no longer mutate dictionary prototypes, disappear on serialization or resolve to inherited values. This applies to newly created stores, legacy migration and loaded documents.
- Private JSON I/O is centralized in `private-json.ts`. Reads open without following symlinks and without blocking on FIFOs, require a regular file, bound both stat size and bytes actually received to 4 MiB, and reject invalid UTF-8 rather than silently altering credential text.
- Writes serialize and check the byte budget before touching disk, exclusively create a private temporary file, flush file content, atomically rename, and clean up on partial-write/flush/rename failure. Directories remain private (`0700`) and documents private (`0600`). The original document remains untouched if serialization or the byte budget fails.
- Existing JSON versions, filenames, OAuth requirements, locks, hidden-account settings and warm-up policy remain unchanged. No migration is required. Oversized/corrupt documents fail closed; back them up and repair them explicitly rather than deleting credentials automatically.

## Validation and limitations

Run `./scripts/check.sh`. Regression tests cover stale presentation callbacks with colliding RPC IDs, bounded queues, queued-only removal, exact UTF-8 budgets, Unicode/duplicate/literal option search, account-name round trips and warm-up claims, exact file-size limits, malformed UTF-8, symlinks/directories/FIFOs, private permissions, preserved previous documents and temporary-file cleanup.

Checks include Swift tests, extension types/lint/format/tests, real installed Pi RPC/codemode compatibility without remote model calls, and Server integration tests. These do not replace manual visual/focus testing in a running macOS app or validate live OAuth/network behavior. Flushing file contents does not claim crash-proof filesystem directory metadata or defend against an attacker controlling the entire agent directory.
