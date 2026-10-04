import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { serializeBoundedCache } = await createJiti(import.meta.url).import(
  "../cache-capacity.ts",
);
const entry = (updatedAt, value = "snapshot") => ({
  key: "key",
  updatedAt,
  value,
});
const document = (entries) => ({ version: 1, entries });

test("under-capacity serialization preserves every snapshot and Unicode byte size", () => {
  const source = document({ old: entry(1, "😀"), fresh: entry(2) });
  const serialized = `${JSON.stringify(source)}\n`;
  assert.equal(
    serializeBoundedCache(source, "fresh", Buffer.byteLength(serialized)),
    serialized,
  );
});

test("evicts oldest snapshots, protects current write regardless of timestamp", () => {
  const source = document({
    newest: entry(100),
    oldest: entry(1),
    current: entry(0),
  });
  const before = structuredClone(source);
  const limit = Buffer.byteLength(
    `${JSON.stringify(document({ newest: source.entries.newest, current: source.entries.current }))}\n`,
  );
  const serialized = serializeBoundedCache(source, "current", limit);
  assert.ok(Buffer.byteLength(serialized) <= limit);
  assert.deepEqual(Object.keys(JSON.parse(serialized).entries), [
    "newest",
    "current",
  ]);
  assert.deepEqual(source, before);
});

test("can evict all previous snapshots and handles prototype-like namespaces", () => {
  const entries = Object.create(null);
  entries.old = entry(1);
  entries.__proto__ = entry(2, "中😀");
  const expected = document(
    JSON.parse(JSON.stringify({ ["__proto__"]: entries.__proto__ })),
  );
  const limit = Buffer.byteLength(`${JSON.stringify(expected)}\n`);
  const result = serializeBoundedCache(document(entries), "__proto__", limit);
  assert.deepEqual(JSON.parse(result), expected);
  assert.equal(Buffer.byteLength(result), limit);
});

test("oversized new snapshots and invalid limits fail without mutation", () => {
  const source = document({
    old: entry(1),
    current: entry(2, "x".repeat(1000)),
  });
  const before = structuredClone(source);
  assert.throws(
    () => serializeBoundedCache(source, "current", 100),
    /缓存过大/u,
  );
  assert.deepEqual(source, before);
  for (const limit of [0, -1, NaN, Infinity, 1.5]) {
    assert.throws(
      () => serializeBoundedCache(source, "current", limit),
      RangeError,
    );
  }
  assert.throws(
    () => serializeBoundedCache(source, "missing", 2000),
    /Missing/u,
  );
});
