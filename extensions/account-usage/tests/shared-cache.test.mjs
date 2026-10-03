import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { setTimeout as delay } from "node:timers/promises";
import { createJiti } from "jiti";
import lockfile from "proper-lockfile";

const root = await mkdtemp(join(tmpdir(), "quota-cache-tests-"));
process.env.PI_CODING_AGENT_DIR = root;
process.env.PI_OFFLINE = "1";
const { readThroughSharedCache } = await createJiti(import.meta.url).import(
  "../shared-cache.ts",
);
const path = join(root, "account-usage-shared-cache.json");

const options = (overrides = {}) => ({
  namespace: "codex",
  key: "synthetic-account",
  maxAgeMs: 60_000,
  force: false,
  signal: new AbortController().signal,
  query: async () => ({ remaining: 80 }),
  ...overrides,
});

try {
  await test("cache hits are cloned, key changes and force query again", async () => {
    let queries = 0;
    const request = options({ query: async () => ({ count: ++queries }) });
    const first = await readThroughSharedCache(request);
    first.count = 999;
    assert.deepEqual(await readThroughSharedCache(request), { count: 1 });
    assert.deepEqual(
      await readThroughSharedCache({ ...request, key: "another-account" }),
      { count: 2 },
    );
    assert.deepEqual(
      await readThroughSharedCache({ ...request, force: true }),
      { count: 3 },
    );
    assert.equal((await stat(path)).mode & 0o777, 0o600);
  });

  await test("contending requests coalesce one query", async () => {
    let queries = 0;
    const request = options({
      namespace: "coalesced",
      query: async () => {
        queries++;
        await delay(50);
        return { remaining: 42 };
      },
    });
    const results = await Promise.all([
      readThroughSharedCache(request),
      readThroughSharedCache(request),
    ]);
    assert.equal(queries, 1);
    assert.deepEqual(results, [{ remaining: 42 }, { remaining: 42 }]);
  });

  await test("abort interrupts lock contention without querying or leaking a lease", async () => {
    const release = await lockfile.lock(path, { realpath: false });
    const controller = new AbortController();
    let queries = 0;
    try {
      const pending = readThroughSharedCache(
        options({
          signal: controller.signal,
          query: async () => ++queries,
        }),
      );
      const assertion = assert.rejects(pending, { name: "AbortError" });
      await delay(30);
      controller.abort();
      await assertion;
      assert.equal(queries, 0);
    } finally {
      await release();
    }
    // A cancelled waiter must never acquire a lock later and strand other sessions.
    await readThroughSharedCache(options({ force: true }));
    await assert.rejects(stat(`${path}.lock`), { code: "ENOENT" });
  });

  await test("already aborted requests perform no query; aborted queries never publish", async () => {
    const controller = new AbortController();
    controller.abort();
    await assert.rejects(
      readThroughSharedCache(options({ signal: controller.signal })),
      { name: "AbortError" },
    );
    const active = new AbortController();
    const before = await readFile(path, "utf8");
    await assert.rejects(
      readThroughSharedCache(
        options({
          force: true,
          signal: active.signal,
          query: async () => {
            active.abort();
            return { remaining: 0 };
          },
        }),
      ),
      { name: "AbortError" },
    );
    assert.equal(await readFile(path, "utf8"), before);
    await readThroughSharedCache(options({ force: true }));
  });

  await test("query failures release the lock and preserve the previous snapshot", async () => {
    const before = await readFile(path, "utf8");
    await assert.rejects(
      readThroughSharedCache(
        options({
          force: true,
          query: async () => {
            throw new Error("offline");
          },
        }),
      ),
      /offline/,
    );
    assert.equal(await readFile(path, "utf8"), before);
    await readThroughSharedCache(options({ force: true }));
  });

  await test("future timestamps and corrupt documents are cache misses", async () => {
    await writeFile(
      path,
      JSON.stringify({
        version: 1,
        entries: {
          codex: {
            key: "synthetic-account",
            updatedAt: Date.now() + 60_000,
            value: "future",
          },
        },
      }),
    );
    assert.deepEqual(await readThroughSharedCache(options()), {
      remaining: 80,
    });
    await writeFile(path, "{broken");
    assert.deepEqual(await readThroughSharedCache(options()), {
      remaining: 80,
    });
  });

  await test("prototype-like namespaces remain ordinary persistent entries", async () => {
    await readThroughSharedCache(
      options({ namespace: "__proto__", force: true }),
    );
    const document = JSON.parse(await readFile(path, "utf8"));
    assert.equal(Object.hasOwn(document.entries, "__proto__"), true);
    assert.deepEqual(document.entries.__proto__.value, { remaining: 80 });
  });
} finally {
  await rm(root, { recursive: true, force: true });
}
