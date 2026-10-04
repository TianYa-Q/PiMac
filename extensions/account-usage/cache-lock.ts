import { performance } from "node:perf_hooks";
import { setTimeout as delay } from "node:timers/promises";
import lockfile from "proper-lockfile";

export const CACHE_LOCK_TIMEOUT_MS = 15_000;

/** Bound contention, not network work. Never race acquisition: late leases must be released. */
export async function acquireCacheLock(
  path: string,
  signal: AbortSignal,
  options: { onCompromised: (error: Error) => void },
  timeoutMs = CACHE_LOCK_TIMEOUT_MS,
): Promise<() => Promise<void>> {
  if (
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs < 1 ||
    timeoutMs > 2_147_483_647
  )
    throw new RangeError("Invalid cache lock timeout");
  const deadline = performance.now() + timeoutMs;
  let compromised: Error | undefined;
  const timeout = () =>
    new DOMException(
      "额度共享缓存繁忙，等待超时，请稍后重试。",
      "TimeoutError",
    );
  for (let attempt = 0; ; attempt++) {
    signal.throwIfAborted();
    if (performance.now() >= deadline) throw timeout();
    try {
      const release = await lockfile.lock(path, {
        realpath: false,
        stale: 5 * 60_000,
        retries: 0,
        onCompromised: (error) => {
          compromised = error;
          options.onCompromised(error);
        },
      });
      // Filesystem acquisition can finish after the deadline or cancellation.
      // Drain it and release ownership before reporting either to the caller.
      if (signal.aborted || performance.now() >= deadline) {
        await releaseCacheLock(release, () => compromised);
        signal.throwIfAborted();
        throw timeout();
      }
      return release;
    } catch (error) {
      signal.throwIfAborted();
      if ((error as NodeJS.ErrnoException).code !== "ELOCKED") throw error;
      const remaining = deadline - performance.now();
      if (remaining <= 0) throw timeout();
      // Fast handoff for short document writes; jitter avoids synchronized waiters.
      const backoff = Math.min(500, 50 * 2 ** Math.min(attempt, 4));
      await delay(
        Math.min(
          remaining,
          Math.max(1, backoff * (0.75 + Math.random() * 0.25)),
        ),
        undefined,
        { signal },
      );
    }
  }
}

export async function releaseCacheLock(
  release: () => Promise<void>,
  getCompromised: () => Error | undefined,
): Promise<void> {
  // proper-lockfile already releases compromised leases. Do not mask that error with ERELEASED.
  try {
    if (!getCompromised()) await release();
  } catch (error) {
    if (!getCompromised()) throw error;
  }
  const compromised = getCompromised();
  if (compromised) throw compromised;
}
