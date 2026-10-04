/** Bound adapters that may ignore cancellation. Late results/errors are observed but never applied.
 * The underlying operation must honor the supplied signal to actually stop network I/O.
 */
export async function withDeadline<T>(
  operation: (signal: AbortSignal) => Promise<T>,
  parent: AbortSignal,
  timeoutMs = 15_000,
): Promise<T> {
  if (
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs < 1 ||
    timeoutMs > 2_147_483_647
  )
    throw new RangeError("Invalid operation timeout");
  parent.throwIfAborted();
  const controller = new AbortController();
  const signal = AbortSignal.any([parent, controller.signal]);
  let onAbort: () => void = () => {};
  const aborted = new Promise<never>((_resolve, reject) => {
    onAbort = () => reject(signal.reason);
    signal.addEventListener("abort", onAbort, { once: true });
  });
  const timer = setTimeout(
    () => controller.abort(new DOMException("额度查询超时。", "TimeoutError")),
    timeoutMs,
  );
  try {
    return await Promise.race([
      Promise.resolve().then(() => {
        signal.throwIfAborted();
        return operation(signal);
      }),
      aborted,
    ]);
  } finally {
    clearTimeout(timer);
    signal.removeEventListener("abort", onAbort);
  }
}
