/** Honor Retry-After only for already-retryable quota GET failures.
 * Never clamp a server's requested wait down: skip retries outside the total budget.
 */
export function quotaRetryDelay(
  retryAfter: string | null,
  remainingMs: number,
  now = Date.now(),
): number | undefined {
  let requestedMs = 0;
  const value = retryAfter?.trim();
  if (value && /^\d+$/u.test(value)) {
    requestedMs = Number(value) * 1000;
  } else if (
    value &&
    /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun), \d{2} (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \d{4} \d{2}:\d{2}:\d{2} GMT$/u.test(
      value,
    )
  ) {
    const date = Date.parse(value);
    if (Number.isFinite(date)) requestedMs = Math.max(0, date - now);
  }
  const delayMs = Math.max(250, requestedMs);
  return Number.isFinite(delayMs) && delayMs < remainingMs
    ? delayMs
    : undefined;
}
