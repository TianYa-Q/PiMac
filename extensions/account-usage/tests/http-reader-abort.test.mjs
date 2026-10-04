import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";
const { readBoundedJson } = await createJiti(import.meta.url).import(
  "../http.ts",
);

test("abort bounds a custom reader that ignores cancellation", async () => {
  const controller = new AbortController();
  let cancelled = 0;
  let released = 0;
  let rejectLate;
  const response = {
    headers: new Headers(),
    body: {
      getReader: () => ({
        read: () =>
          new Promise((_resolve, reject) => {
            rejectLate = reject;
          }),
        cancel: () => {
          cancelled++;
          return new Promise(() => {});
        },
        releaseLock: () => {
          released++;
        },
      }),
    },
  };
  const pending = readBoundedJson(response, 64, controller.signal);
  await Promise.resolve();
  controller.abort(new Error("caller cancelled"));
  await assert.rejects(pending, /caller cancelled/u);
  assert.ok(cancelled > 0);
  assert.equal(released, 1);
  rejectLate(new Error("late transport failure"));
  await new Promise((resolve) => setImmediate(resolve));
});
