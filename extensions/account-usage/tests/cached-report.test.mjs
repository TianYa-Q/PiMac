import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";
const { buildCachedReport, formatCachedReport } = await createJiti(
  import.meta.url,
).import("../cached-report.ts");
const usage = (accountName, extra = {}) => ({
  accountName,
  capturedAt: 1000,
  primary: { remainingPercent: 42, resetAt: 2000, windowSeconds: 18000 },
  ...extra,
});
const options = {
  provider: "openai",
  visibleNames: ["work", "missing", "failed", "work"],
  usages: [
    usage("work"),
    usage("failed", { error: "secret-token", credential: "secret" }),
    usage("hidden"),
  ],
  activeAccount: "work",
  now: 2000,
  maxAgeMs: 10000,
};

test("cached JSON uses explicit fields, visible identities and missing rows", () => {
  const report = buildCachedReport(options);
  assert.deepEqual(
    report.accounts.map((row) => row.name),
    ["work", "missing", "failed"],
  );
  assert.deepEqual(
    report.accounts.map((row) => row.status),
    ["available", "missing", "failed"],
  );
  assert.equal(report.accounts[0].active, true);
  assert.equal(report.accounts[0].freshness, "fresh");
  assert.equal(report.accounts[1].freshness, "unknown");
  assert.equal(report.accounts[2].primary, undefined);
  assert.doesNotMatch(JSON.stringify(report), /secret|hidden|credential/u);
  assert.equal(options.usages[1].error, "secret-token");
});

test("cached reports preserve sample age and show partially missing telemetry", () => {
  const report = buildCachedReport({ ...options, now: 20000 });
  assert.equal(report.accounts[0].freshness, "stale");
  assert.equal(
    buildCachedReport({ ...options, now: 0 }).accounts[0].freshness,
    "future",
  );
  const text = formatCachedReport(
    report,
    options.usages,
    options.activeAccount,
    options.maxAgeMs,
  );
  assert.match(text, /账户 missing：暂无有效快照/u);
  assert.doesNotMatch(text, /hidden/u);
  assert.match(text, /已过期/u);
});
