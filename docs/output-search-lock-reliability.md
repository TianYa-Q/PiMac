# Output search and extension lock reliability

## PiMac

- Tool text details now switch between the beginning and end of retained output. Both modes scan at most 128 KiB / 2,000 native text lines, without scanning the whole output to find its line count. CRLF, CR, LF, NEL and Unicode line/paragraph separators count correctly in either direction. Unicode scalars are never split by the byte limit.
- Literal search adds independent case-sensitive (`Aa`) and whole-word (`ab`) controls. Word boundaries include Unicode letters/numbers, combining marks and underscores, including astral characters. Search never executes user-supplied regular expressions.
- `ToolOutputSearchState` owns the bounded presentation, matches, options and navigation. Navigation and wrapping no longer rebuild or rescan output. Changes beyond an unchanged head preview do not invalidate its matches. Search results are capped at 1,000; `+` appears only when another actual match exists.
- Head-mode streaming appends preserve the selected result when its range remains valid. Moving tail windows reset navigation because relative offsets no longer identify the same original text. Replacing native text invalidates the last applied search range, so the same range can be reapplied; unrelated updates still preserve manual selection.
- Copy and export continue to use complete retained output. Search covers only the selected preview window. This does not restore rich tool output omitted by official V2.

## Pi account-usage extension

Shared-cache lock ownership is extracted into `cache-lock.ts`, shared by namespace and document locks.

- Each acquisition has a monotonic 15-second contention budget instead of 360 fixed half-second retries.
- Initial retries use short handoffs, then capped exponential backoff with jitter to reduce synchronized multi-process wakeups.
- Cancellation interrupts retry sleeps. Timeouts never remove another process's lease, bypass locking, query under someone else's ownership, or overwrite cached quota.
- Filesystem acquisition is deliberately **not** raced against abort/timeout: if it finishes late, the newly acquired lease is released before returning the error. A permanently stalled filesystem operation is not forcibly bounded by this policy.
- Compromised leases retain their meaningful error without double release. Non-contention filesystem errors fail immediately.
- Provider isolation, cache format, account identity checks, query deadlines and rotation policy remain unchanged.

## Validation

New tests cover Unicode search, literal metacharacters, exact match-cap reporting, navigation overflow, stream append/shrink, tail window movement, reverse preview bounds, surrogate-pair word boundaries, native selection reapplication, invalid lock budgets, contention timeout, cancellation, late acquisition cleanup and lease compromise.

Run `./scripts/check.sh` for Swift formatting/tests, watcher tests, extension TypeScript/lint/format/tests, installed Pi compatibility and sidecar checks/tests. A real interactive macOS UI acceptance pass is still recommended; automated tests are not a visual acceptance claim.
