import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { requestBoundedJson } = await createJiti(import.meta.url).import(
  "../http.ts",
);
const originalFetch = globalThis.fetch;
const options = () => ({
  headers: { Authorization: "Bearer synthetic" },
  signal: new AbortController().signal,
  maxBytes: 64,
});

try {
  await test("invalid size limits fail before sending credentials", async () => {
    let calls = 0;
    globalThis.fetch = async () => {
      calls++;
      return Response.json({});
    };
    for (const maxBytes of [0, -1, 1.5, NaN, Infinity]) {
      await assert.rejects(
        requestBoundedJson("https://example.test", {
          ...options(),
          maxBytes,
        }),
        RangeError,
      );
    }
    assert.equal(calls, 0);
  });

  await test("invalid deadlines, retry budgets and insecure URLs never send credentials", async () => {
    let calls = 0;
    globalThis.fetch = async () => {
      calls++;
      return Response.json({});
    };
    for (const timeoutMs of [0, -1, 1.5, NaN, Infinity, 2_147_483_648]) {
      await assert.rejects(
        requestBoundedJson("https://example.test", { ...options(), timeoutMs }),
        RangeError,
      );
    }
    for (const retries of [-1, 2, NaN, null]) {
      await assert.rejects(
        requestBoundedJson("https://example.test", { ...options(), retries }),
        RangeError,
      );
    }
    for (const url of [
      "http://example.test",
      "file:///tmp/quota",
      "https://user:password@example.test",
      "not a URL",
    ]) {
      await assert.rejects(requestBoundedJson(url, options()), TypeError);
    }
    assert.equal(calls, 0);
  });

  await test("transient HTTP failure is cancelled and retried exactly once", async () => {
    let calls = 0;
    let cancelled = false;
    globalThis.fetch = async (_url, init) => {
      assert.equal(init.redirect, "error");
      calls++;
      if (calls > 1) return Response.json({ ok: true });
      return new Response(
        new ReadableStream({
          cancel() {
            cancelled = true;
          },
        }),
        { status: 503 },
      );
    };
    assert.deepEqual(
      await requestBoundedJson("https://example.test", options()),
      { ok: true },
    );
    assert.equal(calls, 2);
    assert.equal(cancelled, true);
  });

  await test("auth, rate-limit, invalid JSON and ordinary server errors are not retried", async () => {
    for (const status of [401, 403, 429, 500, 200]) {
      let calls = 0;
      globalThis.fetch = async () => {
        calls++;
        return new Response("not JSON or a safe error message", { status });
      };
      await assert.rejects(
        requestBoundedJson("https://example.test", options()),
      );
      assert.equal(calls, 1);
    }
  });

  await test("persistent network failure has a bounded retry budget", async () => {
    let calls = 0;
    globalThis.fetch = async () => {
      calls++;
      throw new TypeError("offline");
    };
    await assert.rejects(
      requestBoundedJson("https://example.test", options()),
      /offline/u,
    );
    assert.equal(calls, 2);
  });

  await test("cancellation interrupts backoff without starting another request", async () => {
    const controller = new AbortController();
    let calls = 0;
    globalThis.fetch = async () => {
      calls++;
      queueMicrotask(() => controller.abort());
      return new Response(null, { status: 503 });
    };
    await assert.rejects(
      requestBoundedJson("https://example.test", {
        ...options(),
        signal: controller.signal,
      }),
      { name: "AbortError" },
    );
    assert.equal(calls, 1);
  });

  await test("deadline covers stalled body and backoff, not just headers", async () => {
    let cancelled = false;
    globalThis.fetch = async () =>
      new Response(
        new ReadableStream({
          cancel() {
            cancelled = true;
          },
        }),
      );
    await assert.rejects(
      requestBoundedJson("https://example.test", {
        ...options(),
        timeoutMs: 20,
      }),
      { name: "TimeoutError" },
    );
    assert.equal(cancelled, true);
    let calls = 0;
    globalThis.fetch = async () => {
      calls++;
      return new Response(null, { status: 502 });
    };
    await assert.rejects(
      requestBoundedJson("https://example.test", {
        ...options(),
        timeoutMs: 20,
      }),
    );
    assert.equal(calls, 1);
  });

  await test("server backoff exceeding the deadline skips retry and cancels its body", async () => {
    let calls = 0;
    let cancelled = false;
    globalThis.fetch = async () => {
      calls++;
      return new Response(
        new ReadableStream({
          cancel() {
            cancelled = true;
          },
        }),
        {
          status: 503,
          headers: { "Retry-After": "60" },
        },
      );
    };
    await assert.rejects(
      requestBoundedJson("https://example.test", {
        ...options(),
        timeoutMs: 500,
      }),
      /HTTP 503/u,
    );
    assert.equal(calls, 1);
    assert.equal(cancelled, true);
  });

  await test("zero Retry-After still uses bounded backoff and one retry", async () => {
    let calls = 0;
    globalThis.fetch = async () =>
      ++calls === 1
        ? new Response(null, { status: 503, headers: { "Retry-After": "0" } })
        : Response.json({ ok: true });
    assert.deepEqual(
      await requestBoundedJson("https://example.test", options()),
      { ok: true },
    );
    assert.equal(calls, 2);
  });

  await test("optional requests can disable retries", async () => {
    let calls = 0;
    globalThis.fetch = async () => {
      calls++;
      return new Response(null, { status: 504 });
    };
    await assert.rejects(
      requestBoundedJson("https://example.test", { ...options(), retries: 0 }),
      /HTTP 504/u,
    );
    assert.equal(calls, 1);
  });
} finally {
  globalThis.fetch = originalFetch;
}
