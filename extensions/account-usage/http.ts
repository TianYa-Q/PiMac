import { setTimeout as delay } from "node:timers/promises";
import { withDeadline } from "./deadline.js";

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
  // Node clamps overflowing timers to 1 ms, turning a long deadline into an
  // immediate abort. Validate before transmitting any credentials.
  if (
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs < 1 ||
    timeoutMs > 2_147_483_647
  )
    throw new RangeError("Invalid request timeout");
  if (
    options.retries !== undefined &&
    options.retries !== 0 &&
    options.retries !== 1
  )
    throw new RangeError("Invalid request retry limit");
  validateSizeLimit(options.maxBytes);
  const endpoint = new URL(url);
  if (endpoint.protocol !== "https:" || endpoint.username || endpoint.password)
    throw new TypeError(
      "Quota endpoints require HTTPS without URL credentials",
    );
  options.signal.throwIfAborted();
  // A custom fetch/transport can ignore abort. Bound the caller as well as I/O,
  // and check the signal before applying any late headers or starting a retry.
  return withDeadline(
    async (signal) => {
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
          if (
            !(error instanceof TypeError) ||
            attempt >= (options.retries ?? 1)
          )
            throw error;
          await delay(250, undefined, { signal });
          continue;
        }
        if (signal.aborted) {
          void response.body?.cancel().catch(() => {});
          signal.throwIfAborted();
        }
        if (response.ok)
          return await readBoundedJson(response, options.maxBytes, signal);
        // A transport's cancel hook can hang; cleanup must not consume the deadline.
        void response.body?.cancel().catch(() => {});
        signal.throwIfAborted();
        if (
          ![502, 503, 504].includes(response.status) ||
          attempt >= (options.retries ?? 1)
        )
          throw new HttpStatusError(response.status);
        await delay(250, undefined, { signal });
      }
    },
    options.signal,
    timeoutMs,
  );
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
  } catch (error) {
    // Some transports reject pending reads with a generic network error on abort.
    // Preserve the caller's cancellation/deadline rather than misreporting an outage.
    signal?.throwIfAborted();
    throw error;
  } finally {
    signal?.removeEventListener("abort", cancel);
    // Stop oversized/invalid bodies immediately; never mask the original error.
    if (reader) {
      // cancel() closes pending reads synchronously, but its underlying source
      // cleanup promise is untrusted and may never settle. Observe errors without
      // awaiting that promise, then release the lock immediately.
      void reader.cancel().catch(() => {});
      reader.releaseLock();
    }
  }
}
