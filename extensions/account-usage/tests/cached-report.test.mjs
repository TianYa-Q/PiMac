import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";
const { buildCachedReport, formatCachedReport, formatCachedCSV } =
  await createJiti(import.meta.url).import("../cached-report.ts");
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

test("CSV preserves numeric telemetry, empty missing rows and private allowlist", () => {
  const csv = formatCachedCSV(buildCachedReport(options));
  assert.match(
    csv,
    /^provider,generated_at_ms,account,active,status,freshness,/u,
  );
  assert.match(
    csv,
    /"openai",2000,"work",true,"available","fresh",1000,42,2000,18000,,,\r\n/u,
  );
  assert.match(csv, /"missing",false,"missing","unknown",,,,,,,\r\n/u);
  assert.doesNotMatch(csv, /secret|hidden|credential/u);
  assert.ok(csv.endsWith("\r\n"));
});

test("CSV quotes multiline names and neutralizes spreadsheet formulas", () => {
  const names = [
    'a,"b"\r\nc',
    "=SUM(1)",
    "+cmd",
    "-cmd",
    "@cmd",
    " \t=cmd",
    "中文 😀",
  ];
  const csv = formatCachedCSV(
    buildCachedReport({ ...options, visibleNames: names, usages: [] }),
  );
  assert.ok(csv.includes('"a,""b""\r\nc"'));
  for (const name of names.slice(1, 6))
    assert.ok(csv.includes('"' + "'" + name + '"'));
  assert.ok(csv.includes('"中文 😀"'));
  const empty = formatCachedCSV(
    buildCachedReport({ ...options, visibleNames: [], usages: [] }),
  );
  assert.equal(empty.split("\r\n").length, 2);
});

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
