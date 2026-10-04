import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";

const { formatUsageHealth, buildUsageHealthReport } = await createJiti(
  import.meta.url,
).import("../health.ts");
const options = {
  provider: "openai",
  managed: true,
  authFailed: false,
  accountNames: ["fresh", "old", "failed", "missing", "hidden", "future"],
  hiddenNames: ["hidden", "removed"],
  usages: [
    {
      accountName: "fresh",
      capturedAt: 999,
      primary: { remainingPercent: 80 },
    },
    {
      accountName: "old",
      capturedAt: 900,
      secondary: { remainingPercent: 60 },
    },
    {
      accountName: "failed",
      capturedAt: 999,
      error: "Bearer secret https://private.test",
    },
    { accountName: "hidden", capturedAt: 999, error: "hidden-secret" },
    {
      accountName: "future",
      capturedAt: 1001,
      primary: { remainingPercent: 90 },
    },
  ],
  maxAgeMs: 100,
  gemini: "failed",
  refreshing: false,
  now: 1000,
};

test("doctor counts only visible snapshots, treats boundary/future dates as stale, never prints errors", () => {
  const report = formatUsageHealth(options);
  assert.match(report, /新鲜 1 · 过期 2 · 失败 1 · 未知 1/u);
  assert.match(report, /可见 5 · 隐藏 1/u);
  assert.match(report, /扩展托管 OAuth/u);
  assert.match(report, /Gemini：查询失败/u);
  for (const value of ["secret", "Bearer", "https://", "hidden-secret"])
    assert.equal(report.includes(value), false);
});

test("JSON health report is versioned, count-only and read-only", () => {
  const report = buildUsageHealthReport(options);
  assert.deepEqual(report, {
    version: 2,
    status: "degraded",
    recommendations: ["refresh_usage"],
    provider: "openai",
    auth: "managed",
    accounts: { total: 6, visible: 5, hidden: 1 },
    snapshots: { fresh: 1, stale: 2, failed: 1, missing: 1 },
    refreshing: false,
    gemini: "failed",
  });
  const text = JSON.stringify(report);
  for (const value of [
    "Bearer",
    "secret",
    "https://",
    "accountName",
    "capturedAt",
  ])
    assert.equal(text.includes(value), false);
});

test("unmanaged auth, failed activation and missing windows are explicit", () => {
  assert.match(
    formatUsageHealth({ ...options, managed: false }),
    /自动轮换不适用/u,
  );
  assert.match(
    formatUsageHealth({ ...options, authFailed: true, refreshing: true }),
    /激活失败/u,
  );
  assert.match(
    formatUsageHealth({ ...options, refreshing: true }),
    /刷新：进行中/u,
  );
  assert.match(
    formatUsageHealth({
      ...options,
      accountNames: ["empty"],
      usages: [{ accountName: "empty", capturedAt: 999 }],
    }),
    /未知 1/u,
  );
});
