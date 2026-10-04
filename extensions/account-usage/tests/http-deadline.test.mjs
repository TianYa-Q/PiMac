import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { requestBoundedJson } = await createJiti(import.meta.url).import(
  "../http.ts",
);
const options = () => ({
  headers: {},
  signal: new AbortController().signal,
  maxBytes: 64,
  timeoutMs: 20,
});

test("deadline bounds fetch even when the transport ignores cancellation", async () => {
  const original = globalThis.fetch;
  try {
    let signal;
    globalThis.fetch = (_url, init) => {
      signal = init.signal;
      return new Promise(() => {});
    };
    await assert.rejects(
      requestBoundedJson("https://example.test", options()),
      { name: "TimeoutError" },
    );
    assert.equal(signal.aborted, true);
  } finally {
    globalThis.fetch = original;
  }
});

test("parent cancellation returns promptly and late headers are discarded and cleaned", async () => {
  const original = globalThis.fetch;
  try {
    let resolve,
      cancelled = 0,
      calls = 0;
    globalThis.fetch = () => {
      calls++;
      return new Promise((done) => {
        resolve = done;
      });
    };
    const controller = new AbortController();
    const work = requestBoundedJson("https://example.test", {
      ...options(),
      timeoutMs: 1000,
      signal: controller.signal,
    });
    await new Promise(setImmediate);
    const reason = new Error("session replaced");
    controller.abort(reason);
    await assert.rejects(work, (error) => error === reason);
    resolve(
      new Response(
        new ReadableStream({
          cancel() {
            cancelled++;
          },
        }),
        { status: 503 },
      ),
    );
    await new Promise(setImmediate);
    assert.equal(calls, 1, "never retry after cancellation");
    assert.equal(cancelled, 1);
  } finally {
    globalThis.fetch = original;
  }
});
