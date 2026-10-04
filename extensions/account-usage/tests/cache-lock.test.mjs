import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { setTimeout as delay } from "node:timers/promises";
import { createJiti } from "jiti";
import lockfile from "proper-lockfile";

const { acquireCacheLock, releaseCacheLock, CACHE_LOCK_TIMEOUT_MS } =
  await createJiti(import.meta.url).import("../cache-lock.ts");
const root = await mkdtemp(join(tmpdir(), "quota-lock-tests-"));
const path = join(root, "cache");
const signal = () => new AbortController().signal;
const options = { onCompromised: () => assert.fail("unexpected compromise") };

try {
  await test("cache wait defaults to a short, finite budget", () => {
    assert.equal(CACHE_LOCK_TIMEOUT_MS, 15_000);
  });

  await test("invalid budgets fail without acquiring filesystem leases", async () => {
    for (const timeout of [0, -1, NaN, Infinity, 1.5, 2_147_483_648]) {
      await assert.rejects(
        acquireCacheLock(path, signal(), options, timeout),
        RangeError,
      );
    }
    await assert.rejects(stat(`${path}.lock`), { code: "ENOENT" });
  });

  await test("contention times out without deleting another owner's lease", async () => {
    const release = await lockfile.lock(path, { realpath: false });
    try {
      await assert.rejects(acquireCacheLock(path, signal(), options, 40), {
        name: "TimeoutError",
      });
      assert.equal((await stat(`${path}.lock`)).isDirectory(), true);
    } finally {
      await release();
    }
    const next = await acquireCacheLock(path, signal(), options);
    await next();
    await assert.rejects(stat(`${path}.lock`), { code: "ENOENT" });
  });

  await test("cancellation interrupts contention without waiting for timeout", async () => {
    const release = await lockfile.lock(path, { realpath: false });
    const controller = new AbortController();
    try {
      const pending = acquireCacheLock(path, controller.signal, options);
      const rejected = assert.rejects(pending, { name: "AbortError" });
      await delay(10);
      controller.abort();
      await rejected;
      assert.equal((await stat(`${path}.lock`)).isDirectory(), true);
    } finally {
      await release();
    }
  });

  await test("late acquisition after timeout or abort drains and releases the lease", async () => {
    const original = lockfile.lock;
    for (const cancel of [false, true]) {
      let acquired, resume;
      const started = new Promise((resolve) => {
        acquired = resolve;
      });
      const gate = new Promise((resolve) => {
        resume = resolve;
      });
      lockfile.lock = async (...args) => {
        const release = await original(...args);
        acquired();
        await gate;
        return release;
      };
      const controller = new AbortController();
      const pending = acquireCacheLock(
        path,
        controller.signal,
        options,
        cancel ? 5000 : 20,
      );
      const rejected = assert.rejects(pending, {
        name: cancel ? "AbortError" : "TimeoutError",
      });
      try {
        await started;
        if (cancel) controller.abort();
        else await delay(40);
        resume();
        await rejected;
        await assert.rejects(stat(`${path}.lock`), { code: "ENOENT" });
      } finally {
        resume();
        await Promise.allSettled([pending]);
        lockfile.lock = original;
      }
    }
  });

  await test("non-contention errors are not retried", async () => {
    const original = lockfile.lock;
    let attempts = 0;
    lockfile.lock = async () => {
      attempts++;
      throw Object.assign(new Error("synthetic denied"), { code: "EACCES" });
    };
    try {
      await assert.rejects(acquireCacheLock(path, signal(), options), {
        code: "EACCES",
      });
      assert.equal(attempts, 1);
    } finally {
      lockfile.lock = original;
    }
  });

  await test("compromised leases preserve their error without releasing twice", async () => {
    const error = new Error("synthetic compromised");
    await assert.rejects(
      releaseCacheLock(
        async () => assert.fail("already released"),
        () => error,
      ),
      error,
    );
  });
} finally {
  await rm(root, { recursive: true, force: true });
}
