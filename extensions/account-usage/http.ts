/** Read untrusted quota JSON with a limit on bytes actually received (including chunked bodies). */
export async function readBoundedJson(
  response: Response,
  maxBytes: number,
  signal?: AbortSignal,
): Promise<Record<string, unknown>> {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1)
    throw new RangeError("Invalid response size limit");
  const reader = response.body?.getReader();
  const cancel = () => {
    void reader?.cancel().catch(() => {});
  };
  signal?.addEventListener("abort", cancel, { once: true });
  try {
    signal?.throwIfAborted();
    const length = Number(response.headers.get("content-length"));
    if (Number.isFinite(length) && length > maxBytes)
      throw new Error("额度响应过大。");
    const chunks: Uint8Array[] = [];
    let size = 0;
    if (reader) {
      for (;;) {
        const { done, value } = await reader.read();
        signal?.throwIfAborted();
        if (done) break;
        size += value.byteLength;
        if (size > maxBytes) throw new Error("额度响应过大。");
        chunks.push(value);
      }
    }
    let value: unknown;
    try {
      value = JSON.parse(
        Buffer.concat(chunks, size).toString("utf8"),
      ) as unknown;
    } catch {
      throw new Error("额度接口返回了无效 JSON。");
    }
    if (typeof value !== "object" || value === null || Array.isArray(value))
      throw new Error("额度接口返回结构无效。");
    return value as Record<string, unknown>;
  } finally {
    signal?.removeEventListener("abort", cancel);
    // Stop oversized/invalid bodies immediately; never mask the original error.
    if (reader) {
      try {
        await reader.cancel();
      } catch {
        /* transport already closed */
      }
      reader.releaseLock();
    }
  }
}
