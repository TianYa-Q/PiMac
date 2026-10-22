import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { validAccountUsages } = await createJiti(import.meta.url).import(
  "../cache-validation.ts",
);
const usage = () => ({
  accountName: "a",
  capturedAt: Date.now(),
  primary: {
    remainingPercent: 50,
    resetAt: 123,
    windowSeconds: 18000,
  },
});

await test("cache telemetry must exactly match requested accounts", () => {
  assert.equal(validAccountUsages([usage()], ["a"]), true);
  assert.equal(
    validAccountUsages([{ ...usage(), error: "offline" }], ["a"]),
    true,
  );
  for (const value of [
    null,
    {},
    [null],
    [],
    [usage(), usage()],
    [{ ...usage(), accountName: "other" }],
    [{ ...usage(), capturedAt: "today" }],
    [{ ...usage(), capturedAt: Infinity }],
    [{ ...usage(), primary: { remainingPercent: -1 } }],
    [{ ...usage(), primary: { remainingPercent: 101 } }],
    [{ ...usage(), secondary: { remainingPercent: 50, resetAt: "later" } }],
    [{ ...usage(), resetCredits: { availableCount: 1.5, credits: [] } }],
    [{ ...usage(), resetCredits: { availableCount: 1, credits: [null] } }],
  ])
    assert.equal(validAccountUsages(value, ["a"]), false);
});
