import assert from "node:assert/strict";
import { test } from "node:test";
import { createJiti } from "jiti";
const { nextAccount } = await createJiti(import.meta.url).import(
  "../rotation.ts",
);
const now = Date.parse("2026-01-01T00:00:00Z");
const usage = (name, short, weekly, days = 7) => ({
  accountName: name,
  capturedAt: now,
  primary: {
    remainingPercent: short,
    resetAt: now / 1000 + 18000,
    windowSeconds: 18000,
  },
  secondary:
    weekly === undefined
      ? undefined
      : {
          remainingPercent: weekly,
          resetAt: now / 1000 + days * 86400,
          windowSeconds: 604800,
        },
});
const choose = (usages, options = {}) =>
  nextAccount({ activeAccount: "active", usages, now, ...options });

test("5% threshold is strict; missing short telemetry and missing active account do not rotate", () => {
  assert.equal(choose([usage("active", 5), usage("spare", 90)]), undefined);
  assert.equal(
    choose([usage("active", 4.9), usage("spare", 90)]).accountName,
    "spare",
  );
  assert.equal(choose([usage("active", 0)]), undefined);
  assert.equal(choose([usage("spare", 90)]), undefined);
  assert.equal(
    choose([{ ...usage("active", 0), primary: undefined }, usage("spare", 90)]),
    undefined,
  );
});
test("hidden, failed, stale, unknown and exhausted candidate quotas are skipped", () => {
  const rows = [
    usage("active", 0),
    usage("hidden", 90),
    { ...usage("failed", 90), error: "failed" },
    { ...usage("stale", 90), capturedAt: now - 180001 },
    usage("nan", NaN),
    usage("low", 5),
    usage("spent", 90, 0),
  ];
  assert.equal(choose(rows, { hiddenAccounts: ["hidden"] }), undefined);
  assert.equal(
    choose([...rows, usage("valid", 90)], { hiddenAccounts: ["hidden"] })
      .accountName,
    "valid",
  );
  assert.equal(
    choose([{ ...usage("active", 0), error: "failed" }, usage("valid", 90)]),
    undefined,
  );
});
test("weekly load balances sustainable percent/day rather than account name", () => {
  const active = usage("active", 50, 50, 6);
  assert.deepEqual(
    choose([active, usage("A", 90, 100, 7), usage("Z", 90, 40, 1)]),
    { accountName: "Z", reason: "weekly-balance" },
  );
  assert.equal(
    choose([active, usage("overused", 90, 25, 6), usage("fresh", 90, 100, 7)])
      .accountName,
    "fresh",
  );
});
test("rebalance has 1.5x hysteresis and can be disabled without disabling urgent rotation", () => {
  assert.equal(
    choose([usage("active", 80, 80, 6), usage("similar", 80, 85, 6)]),
    undefined,
  );
  assert.equal(
    choose([usage("active", 80, 50, 6), usage("near", 80, 40, 1)], {
      allowRebalance: false,
    }),
    undefined,
  );
  assert.equal(
    choose([usage("active", 1, 50, 6), usage("near", 80, 40, 1)], {
      allowRebalance: false,
    }).accountName,
    "near",
  );
});
test("exhausted weekly active quota is urgent even with healthy 5h quota", () => {
  assert.equal(
    choose([usage("active", 80, 5), usage("spare", 80, 80)], {
      allowRebalance: false,
    }).reason,
    "low-quota",
  );
});
test("invalid or expired windows never receive a reset urgency bonus", () => {
  assert.equal(
    choose([usage("active", 50, 70), usage("impossible", 90, 100, 8)]),
    undefined,
  );
  assert.equal(
    choose([usage("active", 0), usage("expired", 90, 100, -1)]),
    undefined,
  );
  assert.equal(
    choose([
      usage("active", 0),
      {
        ...usage("expired", 90),
        primary: {
          remainingPercent: 90,
          windowSeconds: 18000,
          resetAt: now / 1000 - 1,
        },
      },
    ]),
    undefined,
  );
});
test("known weekly telemetry wins urgent selection; unknown weekly retains deterministic fallback", () => {
  assert.equal(
    choose([usage("active", 0), usage("A", 90), usage("Z", 90, 90)])
      .accountName,
    "Z",
  );
  assert.equal(
    choose([usage("active", 0), usage("account10", 90), usage("account2", 90)])
      .accountName,
    "account2",
  );
});
