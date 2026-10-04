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
const {
  queryAntigravityUsage,
  antigravityGUIStatus,
  formatAntigravityStatus,
  validAntigravityUsageState,
} = await jiti.import("../antigravity.ts");

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

await test("Gemini credential lookup cannot hang the refresh; shutdown still cancels", async () => {
  const ctx = {
    modelRegistry: { getApiKeyForProvider: () => new Promise(() => {}) },
  };
  const parent = new AbortController();
  const result = await queryAntigravityUsage(ctx, parent.signal, 10);
  assert.equal(result.kind, "failed");
  assert.match(result.error, /超时/u);
  const work = queryAntigravityUsage(ctx, parent.signal);
  parent.abort();
  await assert.rejects(work, { name: "AbortError" });
});

await test("Gemini sample time survives GUI projection and drives TUI warnings", () => {
  const theme = { fg: (_color, text) => text, bold: (text) => text };
  const state = {
    kind: "loaded",
    capturedAt: 1000,
    usage: {
      groups: [],
      models: [{ modelId: "gemini", remainingFraction: 0.5 }],
    },
  };
  assert.equal(antigravityGUIStatus(state, true).capturedAt, 1000);
  assert.doesNotMatch(
    formatAntigravityStatus(state, true, theme, 2000, 10000),
    /已过期|采样时间未知/u,
  );
  assert.match(
    formatAntigravityStatus(state, false, theme, 11000, 10000),
    /已过期/u,
  );
  assert.match(formatAntigravityStatus(state, false, theme, 999), /时间超前/u);
  assert.match(
    formatAntigravityStatus({ ...state, capturedAt: undefined }, false, theme),
    /时间未知/u,
  );
  for (const capturedAt of [true, "1000", NaN, Infinity, -1]) {
    assert.equal(validAntigravityUsageState({ ...state, capturedAt }), false);
  }
});
