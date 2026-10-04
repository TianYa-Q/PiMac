# Search and diagnostic reliability round

## Pi Mac

Session search (⇧⌘F) now accepts scoped conditions alongside existing AND words,
quoted phrases and exclusions:

- `title:库存 text:"修复 完成"` finds the title and visible message text separately.
- `-title:废弃 -text:秘密` excludes titles/messages in their own scopes.
- Prefixes are case-insensitive; unknown prefixes remain literal text.
- Empty prefixes and unfinished quotes are handled while typing.

The sidebar exposes title/text insertion buttons, multiline syntax help, and an
explicit retry action after a Server read failure. Blank/incomplete conditions
clear old errors rather than showing an indefinite searching state.

The same query planner drives local and Server indexing. Rejected titles are
skipped before transcript I/O; title-only queries do not fetch Server messages.
Content queries still search only visible user/assistant messages, not tool
outputs or discarded branches. Local cancelled/failed reads are not cached, and
file metadata is checked again before caching an index built during an append.

## account-usage extension

`/usage doctor json` emits a version-1 JSON health report through the existing
notification channel. It shares the human-readable doctor's calculation and
contains provider/auth state, account counts, snapshot counts, refresh activity
and Gemini snapshot state. It contains no account names, IDs, credentials or
provider error strings. Like `/usage doctor`, it does not query the network,
write auth/session data, warm up models or switch accounts. This is snapshot
health, not a live connectivity test; print/headless mode may ignore UI notices.

Diagnostic error serialization is now a standalone, tested module. Error
`name`, `code` and `syscall` use finite allowlists instead of accepting arbitrary
provider-controlled strings. Recursive causes and aggregate errors remain
bounded, and unknown messages/properties are omitted. Private failure logs still
include the existing account-name context for troubleshooting; the count-only
JSON doctor does not. Unknown transport codes are intentionally omitted.

HTTP body-reader failures check the owning abort signal before rethrowing, so a
transport's generic read error does not replace a user cancellation or timeout.
Readers are still cancelled and unlocked on every exit.

## Included pre-existing changes

The commit also retains the working tree's original improvements: Server-owned
active session ordering, mobile archive read allowlisting, upstream-owned tunnel
recovery (removing host protocol/watchdog overrides), and dev-app restart cleanup
with bounded exponential backoff. Their regression tests are preserved.

## Validation

`./scripts/check.sh` runs Swift formatting/tests, Python dev-supervisor tests,
extension typechecking/lint/format/tests, installed Pi compatibility checks and
Server checks/integration tests. Tests use synthetic accounts and mock model
requests; live login, real quota endpoints, tunnel outage recovery and visual
interaction still require manual validation.
