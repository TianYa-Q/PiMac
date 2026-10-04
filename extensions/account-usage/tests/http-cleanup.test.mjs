import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { readBoundedJson, requestBoundedJson } = await createJiti(
  import.meta.url,
).import("../http.ts");
const never = () => new Promise(() => {});
const bounded = (work) =>
  Promise.race([
    work,
    new Promise((_, reject) => {
      const timer = setTimeout(
        () => reject(new Error("cleanup blocked")),
        1000,
      );
      work.finally(() => clearTimeout(timer)).catch(() => {});
    }),
  ]);

test("throwing custom reader cleanup never masks parse failures or success", async () => {
  for (const payload of ["invalid", '{"ok":true}']) {
    let read = false;
    const response = {
      headers: new Headers(),
      body: {
        getReader: () => ({
          read: async () => {
            if (read) return { done: true };
            read = true;
            return { done: false, value: new TextEncoder().encode(payload) };
          },
          cancel: () => {
            throw new Error("cleanup failure");
          },
          releaseLock: () => {
            throw new Error("release failure");
          },
        }),
      },
    };
    const work = readBoundedJson(response, 64);
    if (payload === "invalid") await assert.rejects(work, /无效 JSON/u);
    else assert.deepEqual(await work, { ok: true });
  }
});

test("throwing HTTP body cleanup preserves status failures", async () => {
  const original = globalThis.fetch;
  try {
    globalThis.fetch = async () => ({
      ok: false,
      status: 401,
      body: {
        cancel: () => {
          throw new Error("cleanup failure");
        },
      },
    });
    await assert.rejects(
      requestBoundedJson("https://example.test", {
        headers: {},
        maxBytes: 64,
        signal: new AbortController().signal,
      }),
      /HTTP 401/u,
    );
  } finally {
    globalThis.fetch = original;
  }
});

test("oversized response returns even if underlying cancellation never settles", async () => {
  const response = new Response(
    new ReadableStream(
      {
        pull(controller) {
          controller.enqueue(new Uint8Array(65));
        },
        cancel: never,
      },
      { highWaterMark: 0 },
    ),
  );
  await assert.rejects(bounded(readBoundedJson(response, 64)), /响应过大/u);
  assert.equal(response.body.locked, false);
});

test("aborted stalled reads preserve the reason despite hanging source cleanup", async () => {
  const response = new Response(new ReadableStream({ cancel: never }));
  const controller = new AbortController();
  const reason = new Error("session replaced");
  const pending = readBoundedJson(response, 64, controller.signal);
  const assertion = assert.rejects(
    bounded(pending),
    (error) => error === reason,
  );
  controller.abort(reason);
  await assertion;
  assert.equal(response.body.locked, false);
});

test("HTTP failure and retry never wait for an error body's cancel promise", async () => {
  const original = globalThis.fetch;
  try {
    for (const status of [401, 503]) {
      let calls = 0;
      globalThis.fetch = async () => {
        calls++;
        if (calls > 1) return Response.json({ ok: true });
        return new Response(new ReadableStream({ cancel: never }), { status });
      };
      const work = bounded(
        requestBoundedJson("https://example.test", {
          headers: {},
          maxBytes: 64,
          timeoutMs: 500,
          signal: new AbortController().signal,
        }),
      );
      if (status === 401) await assert.rejects(work, /HTTP 401/u);
      else assert.deepEqual(await work, { ok: true });
      assert.equal(calls, status === 401 ? 1 : 2);
    }
  } finally {
    globalThis.fetch = original;
  }
});
