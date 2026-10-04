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
  const worker = async () => {
    while (!failed) {
      signal?.throwIfAborted();
      const index = nextIndex++;
      if (index >= values.length) return;
      try {
        results[index] = await mapper(values[index]!);
      } catch (error) {
        failed = true;
        throw error;
      }
    }
  };
  const settled = await Promise.allSettled(
    Array.from({ length: Math.min(concurrency, values.length) }, worker),
  );
  signal?.throwIfAborted();
  const failure = settled.find((result) => result.status === "rejected");
  if (failure?.status === "rejected") throw failure.reason;
  return results;
}
