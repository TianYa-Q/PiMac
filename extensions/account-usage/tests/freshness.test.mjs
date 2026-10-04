import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const jiti = createJiti(import.meta.url);
const { sampleFreshness, sampleAgeLabel } =
  await jiti.import("../freshness.ts");
const { formatUsageSummary, formatStatusSegment } =
  await jiti.import("../format.ts");
const theme = { fg: (_, text) => text, bold: (text) => text };
const now = 1_000_000;
const usage = {
  accountName: "work",
  capturedAt: now,
  primary: { remainingPercent: 80, windowSeconds: 18_000 },
};

test("sample age distinguishes boundary, future and unknown clocks", () => {
  assert.equal(sampleFreshness(now - 59_999, now, 60_000), "fresh");
  assert.equal(sampleFreshness(now - 60_000, now, 60_000), "stale");
  assert.equal(sampleFreshness(now + 1, now, 60_000), "future");
  for (const value of [undefined, NaN, Infinity, -1])
    assert.equal(sampleFreshness(value, now, 60_000), "unknown");
  assert.equal(sampleFreshness(now, NaN, 60_000), "unknown");
  assert.match(sampleAgeLabel(now - 60_000, now, 60_000), /1 分钟前 · 已过期/u);
});

test("TUI status warns on stale/unknown samples and summaries always disclose sample age", () => {
  assert.doesNotMatch(
    formatStatusSegment(usage, "work", theme, now),
    /过期|采样/u,
  );
  const old = { ...usage, capturedAt: now - 60_000 };
  assert.match(formatStatusSegment(old, "work", theme, now, 60_000), /已过期/u);
  assert.doesNotMatch(
    formatStatusSegment(old, "work", theme, now, 180_000),
    /已过期/u,
  );
  assert.match(
    formatUsageSummary([old], "work", now, 60_000),
    /1 分钟前 · 已过期/u,
  );
  assert.match(formatUsageSummary([usage], "work", now), /0 秒前/u);
  assert.match(
    formatUsageSummary([{ ...usage, capturedAt: undefined }], "work", now),
    /采样时间未知/u,
  );
  assert.match(
    formatStatusSegment({ ...usage, capturedAt: now + 1 }, "work", theme, now),
    /系统时钟/u,
  );
  assert.match(
    formatUsageSummary(
      [{ accountName: "empty", capturedAt: now }],
      undefined,
      now,
    ),
    /额度未知/u,
  );
});
