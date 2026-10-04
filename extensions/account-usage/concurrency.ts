/** Ordered, bounded work. Stop dequeuing after cancellation or the first failure,
 * and drain active workers before returning so callers can safely release leases.
 */
export async function mapWithConcurrency<T, R>(
  values: readonly T[],
  concurrency: number,
  mapper: (value: T) => Promise<R>,
  signal?: AbortSignal,
): Promise<R[]> {
  if (!Number.isSafeInteger(concurrency) || concurrency < 1)
    throw new RangeError("Invalid concurrency limit");
  signal?.throwIfAborted();
  const results: R[] = [];
  let nextIndex = 0;
  let failed = false;
  let firstFailure: unknown;
  const worker = async () => {
    while (!failed) {
      signal?.throwIfAborted();
      const index = nextIndex++;
      if (index >= values.length) return;
      try {
        results[index] = await mapper(values[index]!);
      } catch (error) {
        if (!failed) firstFailure = error;
        failed = true;
        return;
      }
    }
  };
  await Promise.allSettled(
    Array.from({ length: Math.min(concurrency, values.length) }, worker),
  );
  signal?.throwIfAborted();
  if (failed) throw firstFailure;
  return results;
}
