import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { readBoundedJson } = await createJiti(import.meta.url).import(
  "../http.ts",
);
const encoder = new TextEncoder();

function streamed(chunks, headers = {}) {
  let cancelled = false;
  let reads = 0;
  const response = new Response(
    new ReadableStream(
      {
        pull(controller) {
          reads++;
          if (chunks.length) controller.enqueue(encoder.encode(chunks.shift()));
          else controller.close();
        },
        cancel() {
          cancelled = true;
        },
      },
      { highWaterMark: 0 },
    ),
    { headers },
  );
  return {
    response,
    get cancelled() {
      return cancelled;
    },
    get reads() {
      return reads;
    },
  };
}

await test("chunked JSON permits exact byte limit and split UTF-8", async () => {
  const bytes = encoder.encode('{"text":"你好"}');
  const response = new Response(
    new ReadableStream({
      start(controller) {
        for (const byte of bytes) controller.enqueue(new Uint8Array([byte]));
        controller.close();
      },
    }),
  );
  assert.deepEqual(await readBoundedJson(response, bytes.length), {
    text: "你好",
  });
  assert.equal(response.body.locked, false);
});

await test("tiny chunks grow bounded storage without losing data", async () => {
  const text = JSON.stringify({ text: "你好".repeat(12_000) });
  const bytes = encoder.encode(text);
  let offset = 0;
  const response = new Response(
    new ReadableStream({
      pull(controller) {
        if (offset === bytes.length) controller.close();
        else controller.enqueue(bytes.subarray(offset, ++offset));
      },
    }),
  );
  assert.deepEqual(
    await readBoundedJson(response, bytes.length),
    JSON.parse(text),
  );
  assert.equal(response.body.locked, false);
});

await test("oversized chunked body stops before consuming remaining chunks", async () => {
  const body = streamed(["12345", "67890", "never consumed"]);
  await assert.rejects(readBoundedJson(body.response, 8), /响应过大/u);
  assert.equal(body.cancelled, true);
  assert.equal(body.reads, 2);
  assert.equal(body.response.body.locked, false);
});

await test("content length is checked before any read but cannot bypass the byte limit", async () => {
  const body = streamed(["never consumed"], { "content-length": "100" });
  await assert.rejects(readBoundedJson(body.response, 8), /响应过大/u);
  assert.equal(body.reads, 0);
  assert.equal(body.cancelled, true);
  const lying = streamed(["123456789"], { "content-length": "1" });
  await assert.rejects(readBoundedJson(lying.response, 8), /响应过大/u);
  assert.equal(lying.cancelled, true);
});

await test("invalid JSON, primitives, arrays and empty bodies are rejected", async () => {
  for (const text of ["{broken", "null", "[]", "123", '"secret"', ""]) {
    await assert.rejects(
      readBoundedJson(new Response(text), 64),
      /JSON|结构无效/u,
    );
  }
  await assert.rejects(readBoundedJson(new Response(null), 64), /JSON/u);
});

await test("malformed UTF-8 cannot silently replace quota text", async () => {
  const bytes = new Uint8Array([123, 34, 120, 34, 58, 34, 0xff, 34, 125]);
  const response = new Response(bytes);
  await assert.rejects(readBoundedJson(response, 64), /无效 JSON/u);
  assert.equal(response.body.locked, false);
});

await test("abort cancels a stalled reader and releases its lock", async () => {
  let cancelled = false;
  const response = new Response(
    new ReadableStream({
      cancel() {
        cancelled = true;
      },
    }),
  );
  const controller = new AbortController();
  const pending = readBoundedJson(response, 64, controller.signal);
  const assertion = assert.rejects(pending, { name: "AbortError" });
  controller.abort();
  await assertion;
  assert.equal(cancelled, true);
  assert.equal(response.body.locked, false);
});

await test("already aborted requests cancel without reading", async () => {
  const controller = new AbortController();
  controller.abort();
  const body = streamed(["never consumed"]);
  await assert.rejects(readBoundedJson(body.response, 64, controller.signal), {
    name: "AbortError",
  });
  assert.equal(body.reads, 0);
  assert.equal(body.cancelled, true);
});
