import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";
const { buildUsageHealthReport, formatUsageHealth } = await createJiti(
  import.meta.url,
).import("../health.ts");
const base = {
  provider: "openai",
  managed: true,
  authFailed: false,
  accountNames: ["account"],
  hiddenNames: [],
  usages: [
    {
      accountName: "account",
      capturedAt: 1000,
      primary: { remainingPercent: 80 },
    },
  ],
  maxAgeMs: 100,
  gemini: "unconfigured",
  refreshing: false,
  now: 1000,
};
test("healthy snapshots need no action; diagnostics never claim network connectivity", () => {
  assert.equal(buildUsageHealthReport(base).status, "healthy");
  assert.deepEqual(buildUsageHealthReport(base).recommendations, []);
  assert.match(formatUsageHealth(base), /无需操作/u);
  assert.match(formatUsageHealth(base), /不代表实时连通/u);
});
test("action priority repairs auth, then visibility, then stale data", () => {
  assert.deepEqual(
    buildUsageHealthReport({
      ...base,
      authFailed: true,
      hiddenNames: ["account"],
      gemini: "failed",
    }).recommendations,
    ["repair_auth", "review_visibility", "refresh_usage"],
  );
  assert.deepEqual(
    buildUsageHealthReport({ ...base, accountNames: [], usages: [] })
      .recommendations,
    ["add_account"],
  );
});
test("refreshing suppresses redundant refresh advice but not authentication repair", () => {
  const report = buildUsageHealthReport({
    ...base,
    authFailed: true,
    usages: [],
    refreshing: true,
  });
  assert.deepEqual(report.recommendations, ["repair_auth"]);
  assert.equal(report.status, "degraded");
  assert.match(
    formatUsageHealth({ ...base, usages: [], refreshing: true }),
    /等待当前刷新完成/u,
  );
});
test("missing and clock-skewed data are attention, not healthy", () => {
  for (const usages of [[], [{ ...base.usages[0], capturedAt: 1001 }]]) {
    const report = buildUsageHealthReport({ ...base, usages });
    assert.equal(report.status, "attention");
    assert.deepEqual(report.recommendations, ["refresh_usage"]);
  }
});
