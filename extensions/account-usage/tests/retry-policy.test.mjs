import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { quotaRetryDelay } = await createJiti(import.meta.url).import(
  "../retry-policy.ts",
);
const now = Date.parse("Wed, 01 Jan 2025 00:00:00 GMT");

test("Retry-After delta seconds and HTTP dates respect a minimum backoff", () => {
  assert.equal(quotaRetryDelay("2", 3000, now), 2000);
  assert.equal(quotaRetryDelay(" 1 ", 3000, now), 1000);
  assert.equal(quotaRetryDelay("0", 3000, now), 250);
  assert.equal(
    quotaRetryDelay("Wed, 01 Jan 2025 00:00:02 GMT", 3000, now),
    2000,
  );
  assert.equal(
    quotaRetryDelay("Tue, 31 Dec 2024 23:59:59 GMT", 3000, now),
    250,
  );
});

test("invalid values use the default and never become an immediate retry", () => {
  for (const value of [
    null,
    "",
    "-1",
    "0.5",
    "NaN",
    "Infinity",
    "2025",
    "bad date",
  ]) {
    const delay = quotaRetryDelay(value, 3000, now);
    assert.equal(delay, value === "2025" ? undefined : 250);
  }
});

test("server waits are never shortened to fit the remaining deadline", () => {
  for (const value of [
    "3",
    "999999999999999999999999999999",
    "9".repeat(400),
  ]) {
    assert.equal(quotaRetryDelay(value, 3000, now), undefined);
  }
  assert.equal(quotaRetryDelay(null, 250, now), undefined);
  assert.equal(quotaRetryDelay(null, -1, now), undefined);
});
