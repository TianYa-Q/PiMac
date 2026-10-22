import assert from "node:assert/strict";
import { after, test } from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createJiti } from "jiti";

const root = await mkdtemp(join(tmpdir(), "quota-deadline-"));
process.env.PI_CODING_AGENT_DIR = root;
after(() => rm(root, { recursive: true, force: true }));
const jiti = createJiti(import.meta.url);
const { withDeadline } = await jiti.import("../deadline.ts");

await test("deadline bounds an adapter that never settles", async () => {
  let signal;
  await assert.rejects(
    withDeadline(
      (value) => {
        signal = value;
        return new Promise(() => {});
      },
      new AbortController().signal,
      10,
    ),
    { name: "TimeoutError" },
  );
  assert.equal(signal.aborted, true);
});

await test("parent cancellation preserves reason and observes late rejection", async () => {
  const parent = new AbortController();
  let reject;
  const work = withDeadline(
    () =>
      new Promise((_resolve, fail) => {
        reject = fail;
      }),
    parent.signal,
  );
  await new Promise(setImmediate);
  const reason = new Error("session replaced");
  parent.abort(reason);
  await assert.rejects(work, (error) => error === reason);
  reject(new Error("late adapter failure"));
  await new Promise(setImmediate);
});

await test("completed work clears timer and invalid deadlines never start work", async () => {
  const parent = new AbortController();
  let signal;
  assert.equal(
    await withDeadline(
      async (value) => {
        signal = value;
        return 42;
      },
      parent.signal,
      10,
    ),
    42,
  );
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(signal.aborted, false);
  for (const timeout of [0, -1, NaN, Infinity, 2 ** 31, 1.5]) {
    await assert.rejects(
      withDeadline(() => assert.fail("must not run"), parent.signal, timeout),
      RangeError,
    );
  }
  parent.abort();
  await assert.rejects(
    withDeadline(() => assert.fail("must not run"), parent.signal),
    { name: "AbortError" },
  );
});
