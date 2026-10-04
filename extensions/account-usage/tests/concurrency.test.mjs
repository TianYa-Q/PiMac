import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { mapWithConcurrency } = await createJiti(import.meta.url).import(
  "../concurrency.ts",
);
const deferred = () => {
  let resolve;
  const promise = new Promise((done) => {
    resolve = done;
  });
  return { promise, resolve };
};

await test("bounded workers preserve input order despite completion order", async () => {
  const gates = Array.from({ length: 4 }, deferred);
  const started = [];
  const work = mapWithConcurrency([0, 1, 2, 3], 2, async (value) => {
    started.push(value);
    await gates[value].promise;
    return value * 2;
  });
  assert.deepEqual(started, [0, 1]);
  gates[1].resolve();
  await new Promise(setImmediate);
  assert.deepEqual(started, [0, 1, 2]);
  gates[2].resolve();
  await new Promise(setImmediate);
  assert.deepEqual(started, [0, 1, 2, 3]);
  gates[3].resolve();
  gates[0].resolve();
  assert.deepEqual(await work, [0, 2, 4, 6]);
});

await test("first failure stops queued work but drains active workers", async () => {
  const gate = deferred();
  const failure = new Error("synthetic failure");
  const started = [];
  let settled = false;
  const work = mapWithConcurrency([0, 1, 2, 3], 2, async (value) => {
    started.push(value);
    if (value === 0) throw failure;
    await gate.promise;
    return value;
  });
  const assertion = assert
    .rejects(work, (error) => error === failure)
    .then(() => {
      settled = true;
    });
  await new Promise(setImmediate);
  assert.equal(settled, false);
  gate.resolve();
  await assertion;
  assert.deepEqual(started, [0, 1]);
});

await test("cancellation never dequeues more work and preserves abort reason", async () => {
  const controller = new AbortController();
  const gate = deferred();
  const started = [];
  const work = mapWithConcurrency(
    [0, 1, 2],
    2,
    async (value) => {
      started.push(value);
      await gate.promise;
      return value;
    },
    controller.signal,
  );
  const reason = new Error("session replaced");
  const assertion = assert.rejects(work, (error) => error === reason);
  controller.abort(reason);
  gate.resolve();
  await assertion;
  assert.deepEqual(started, [0, 1]);
  await assert.rejects(
    mapWithConcurrency([], 1, async () => {}, controller.signal),
    (error) => error === reason,
  );
});

await test("empty inputs, undefined values and invalid limits are explicit", async () => {
  assert.deepEqual(await mapWithConcurrency([], 2, async () => {}), []);
  assert.deepEqual(
    await mapWithConcurrency(
      [undefined, 2],
      10,
      async (value) => value ?? "empty",
    ),
    ["empty", 2],
  );
  for (const limit of [0, -1, 1.5, NaN, Infinity]) {
    await assert.rejects(
      mapWithConcurrency([1], limit, async () => 1),
      RangeError,
    );
  }
});
