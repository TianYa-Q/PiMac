# Account snapshots and extension lifecycle hardening

## Scope

This round focuses on a complete Pi extension → server status → native account UI path. The checkout was clean before work began. No credentials, live OAuth flows, paid model calls, global Pi settings or upstream sidecar sources were changed.

## Stability

- Keep the provider's per-account `capturedAt` through shared/session projections; do not confuse a newly published status with a newly queried quota.
- Reject booleans masquerading as JSON numbers, non-finite values, percentages outside 0–100, unsupported dates, fractional/overflowing reset-credit counts and unsafe window lengths.
- Reject explicitly invalid publication timestamps without bypassing existing out-of-order protection. Version-1/2 compatibility and missing legacy timestamps remain supported.
- Bound quota status parsing to 1 MiB; remove empty/duplicate account identities and duplicate Gemini row IDs before SwiftUI sees them.
- Capture the store and session cancellation owner before asynchronous account interactions. Revalidate after dialog responses and account mutations; an obsolete menu cannot open a login, switch account or alter visibility on a replacement provider/session. Waiting for automatic rotation cannot silently migrate a manual switch to another context.

## Features and UI

- Account rows show quota sample age. Busy snapshots expire at 60 seconds, idle snapshots at 180 seconds; more than five seconds into the future is clock skew. Expiration is a warning, not an automatic network query or account switch.
- A small independent minute-based timeline updates freshness without invalidating the entire equatable account card. Missing old timestamps are explicitly unknown.
- Refresh buttons show native progress and accessible labels. Missing quotas no longer imply a permanent in-flight query.
- Account management has case-insensitive, whitespace-trimmed search when more than four accounts are present, stable filtered row identities, lazy rows and a no-match state.
- The extension's account menu exposes a read-only Health Check backed by the existing `/usage doctor` report. The native adapter supports old menus without this action.

## Refactoring

`AccountQuotaCard.swift` owns the quota bar, reset countdown, credit popover and account card previously embedded in `ContentView.swift`. `AccountQuotaFreshnessView.swift` isolates time-driven presentation. `AccountUsageSnapshot.swift` isolates numeric/date validation and freshness policy. The extension uses a shared health-report path and captured context guards instead of store-only checks.

## Validation

`./scripts/check.sh` passed: strict Swift formatting, sidecar preparation, 244 Swift tests, extension typecheck/lint/format checks, 79 extension tests, fast-extension tests, Pi compatibility tests and 80 server-sidecar tests. New regressions cover hostile numeric payloads, duplicate IDs, invalid/oversized envelopes, timestamps/freshness boundaries, search/menu compatibility, provider replacement, same-provider shutdown/restart and read-only menu diagnostics.

Mocks and native integration tests do not establish live quota endpoint authorization. Visual smoke testing with many real accounts, dark/light appearance and VoiceOver remains manual. Existing npm/nvm prefix and experimental SQLite warnings do not fail the check.
