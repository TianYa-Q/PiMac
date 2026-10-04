# Usage dashboard and extension diagnostic hardening

## PiMac

- Split transcript scanning/indexing into `UsageScanner.swift` and pure metric/CSV policy into `UsageArithmetic.swift`, leaving `UsageDashboard.swift` responsible for presentation.
- Scan JSONL in 64 KiB reads, using the shared LF decoder with a 16 MiB per-record limit. Oversized records are skipped through their next LF; later records and valid final records without LF remain usable. Memory for raw records no longer scales with the whole transcript (aggregated buckets still scale with distinct days/models/sessions).
- Stop at the file size observed when scanning began rather than chasing a growing transcript. Re-stat using a fresh URL afterward so Foundation's resource-value cache cannot hide changed metadata. Unstable reads preserve an existing index and retry next time.
- Reject Boolean, negative, fractional and out-of-range token values and invalid costs. Saturate cumulative token/cost sums instead of trapping or producing infinity. Cache-hit calculations avoid integer overflow. Version-3 indexes rebuild older caches and validate cached metrics; session files are untouched.
- Sort equal-token model/project totals by stable names/paths.
- Add CSV export for the selected period, including totals, models and projects. The save dialog chooses the destination; failures produce an alert. Export contains aggregation only, not message bodies, but project paths/model names may be private: review before sharing. Cells are quoted, Unicode is retained, and formula-leading labels are neutralized for spreadsheets.
- Add search and all/shown/hidden filters to the native account visibility dialog, with counts and an empty state. Filtered rows preserve the original extension option strings and identities. Lazy rows bound view construction; no wire-protocol change.

## account-usage extension

Diagnostic writes now use a separate, injectable `private-log.ts` helper:

- Reject symlinks, multi-link files, directories and special files. Use POSIX no-follow/nonblocking opens, validate descriptors, and change permissions through the descriptor rather than a path.
- Rotate before an append crosses 1 MiB; retain one backup. Replacing a backup symlink does not follow or modify its target. Each serialized record has a 16 KiB ceiling; context strings and elapsed time are bounded/validated.
- Logging remains best-effort. Errors never interrupt quota refresh. Multi-process rotation is not transactional and short writes may split lines; this is not an audit log. The helper assumes the parent agent directory is trusted.
- Existing credential, cache and quota RPC formats are unchanged. No added network requests, retries, warm-ups or dependencies.

## Validation

`./scripts/check.sh` validates formatting, Swift tests, extension types/lint/format/tests, Pi compatibility and Server tests. New regressions cover oversized JSONL recovery, final records, numeric saturation, deterministic ranking, CSV escaping/formula safety, visibility filtering, private log rotation/permissions/unsafe paths, and isolated FIFO rejection.

Manual acceptance still required: visual layout and accessibility in the running macOS app; save/export success, cancellation and filesystem errors; real account login and quota endpoint access. Tests use synthetic data and do not prove live provider authorization.
