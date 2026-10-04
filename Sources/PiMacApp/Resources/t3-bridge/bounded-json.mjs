// Untrusted HTTP bodies: bound actual bytes and allocation, including tiny chunks.
// Never await a transport's cancellation hook: it can outlive the request deadline.
export function discardBody(response) {
  try { void response.body?.cancel().catch(() => {}); } catch { /* best effort */ }
}

export async function boundedJSON(response, { maxBytes = 256 * 1024, signal } = {}) {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new RangeError('Invalid body limit');
  signal?.throwIfAborted();
  const reader = response.body?.getReader();
  const onAbort = () => { void reader?.cancel().catch(() => {}); };
  signal?.addEventListener('abort', onAbort, { once: true });
  try {
    const length = Number(response.headers.get('content-length'));
    if (Number.isFinite(length) && length > maxBytes) throw new Error('oversize');
    let bytes = new Uint8Array(Math.min(maxBytes, 16384)), size = 0;
    if (reader) for (;;) {
      signal?.throwIfAborted();
      const { done, value } = await reader.read();
      signal?.throwIfAborted();
      if (done) break;
      const next = size + value.byteLength;
      if (next > maxBytes) throw new Error('oversize');
      if (next > bytes.length) {
        const grown = new Uint8Array(Math.min(maxBytes, Math.max(next, bytes.length * 2)));
        grown.set(bytes.subarray(0, size)); bytes = grown;
      }
      bytes.set(value, size); size = next;
    }
    const body = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, size)));
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('shape');
    return body;
  } catch (error) {
    signal?.throwIfAborted();
    throw error;
  } finally {
    signal?.removeEventListener('abort', onAbort);
    if (reader) {
      void reader.cancel().catch(() => {});
      reader.releaseLock();
    }
  }
}
