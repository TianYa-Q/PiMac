import { setTimeout as delay } from "node:timers/promises";

function validateSizeLimit(maxBytes: number): void {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1)
    throw new RangeError("Invalid response size limit");
}

export class HttpStatusError extends Error {
  constructor(readonly status: number) {
    super(`额度接口返回 HTTP ${status}。`);
  }
}

/** Only idempotent quota GETs are retried, never OAuth refreshes or rate-limit errors.
 * One deadline covers headers, body and backoff; credentials never follow redirects.
 */
export async function requestBoundedJson(
  url: string,
  options: {
    headers: Record<string, string>;
    signal: AbortSignal;
    maxBytes: number;
    timeoutMs?: number;
    retries?: 0 | 1;
  },
): Promise<Record<string, unknown>> {
  const timeoutMs = options.timeoutMs ?? 15_000;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1)
    throw new RangeError("Invalid request timeout");
  validateSizeLimit(options.maxBytes);
  options.signal.throwIfAborted();
  const controller = new AbortController();
  const signal = AbortSignal.any([options.signal, controller.signal]);
  const timer = setTimeout(
    () =>
      controller.abort(new DOMException("额度接口请求超时。", "TimeoutError")),
    timeoutMs,
  );
  try {
    for (let attempt = 0; ; attempt++) {
      signal.throwIfAborted();
      let response: Response;
      try {
        response = await fetch(url, {
          headers: options.headers,
          redirect: "error",
          signal,
        });
      } catch (error) {
        signal.throwIfAborted();
        if (!(error instanceof TypeError) || attempt >= (options.retries ?? 1))
          throw error;
        await delay(250, undefined, { signal });
        continue;
      }
      if (response.ok)
        return await readBoundedJson(response, options.maxBytes, signal);
      await response.body?.cancel().catch(() => {});
      signal.throwIfAborted();
      if (
        ![502, 503, 504].includes(response.status) ||
        attempt >= (options.retries ?? 1)
      )
        throw new HttpStatusError(response.status);
      await delay(250, undefined, { signal });
    }
  } finally {
    clearTimeout(timer);
  }
}

/** Read untrusted quota JSON with a limit on bytes actually received (including chunked bodies). */
export async function readBoundedJson(
  response: Response,
  maxBytes: number,
  signal?: AbortSignal,
): Promise<Record<string, unknown>> {
  validateSizeLimit(maxBytes);
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
    // Geometric storage bounds memory even for millions of tiny chunks. Keeping
    // every chunk until Buffer.concat would amplify the body limit into GBs.
    let bytes = new Uint8Array(Math.min(maxBytes, 16_384));
    let size = 0;
    if (reader) {
      for (;;) {
        const { done, value } = await reader.read();
        signal?.throwIfAborted();
        if (done) break;
        const nextSize = size + value.byteLength;
        if (nextSize > maxBytes) throw new Error("额度响应过大。");
        if (nextSize > bytes.length) {
          const grown = new Uint8Array(
            Math.min(maxBytes, Math.max(nextSize, bytes.length * 2)),
          );
          grown.set(bytes.subarray(0, size));
          bytes = grown;
        }
        bytes.set(value, size);
        size = nextSize;
      }
    }
    let value: unknown;
    try {
      value = JSON.parse(
        new TextDecoder("utf-8", { fatal: true }).decode(
          bytes.subarray(0, size),
        ),
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
