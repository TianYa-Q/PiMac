import type { AccountUsage, UsageWindow } from "./types.js";

const FIVE_HOURS = 18_000;
const WEEK = 604_800;
export const REBALANCE_COOLDOWN_MS = 10 * 60_000;
const MAX_USAGE_AGE_MS = 3 * 60_000;

export type RotationDecision = {
  accountName: string;
  reason: "low-quota" | "weekly-balance";
};

function remaining(usage: AccountUsage, seconds: number, now: number) {
  const window = [usage.primary, usage.secondary].find(
    (value): value is UsageWindow => value?.windowSeconds === seconds,
  );
  if (
    !window ||
    !Number.isFinite(window.remainingPercent) ||
    window.remainingPercent < 0 ||
    window.remainingPercent > 100 ||
    (window.resetAt !== undefined && window.resetAt * 1_000 <= now)
  )
    return undefined;
  return window.remainingPercent;
}

function weeklyBudget(usage: AccountUsage, now: number) {
  const value = remaining(usage, WEEK, now);
  const reset = [usage.primary, usage.secondary].find(
    (window) => window?.windowSeconds === WEEK,
  )?.resetAt;
  if (value === undefined || reset === undefined) return undefined;
  const seconds = reset - now / 1_000;
  if (!Number.isFinite(seconds) || seconds <= 0 || seconds > WEEK)
    return undefined;
  const days = seconds / 86_400;
  return {
    rate: Math.max(0, value - 5) / Math.max(0.25, days),
    paced: value >= (100 * days) / 7 - 15,
  };
}

/** Pure policy: never use hidden, failed, stale or unknown short-window telemetry. */
export function nextAccount({
  activeAccount,
  usages,
  hiddenAccounts = [],
  now = Date.now(),
  allowRebalance = true,
}: {
  activeAccount: string;
  usages: readonly AccountUsage[];
  hiddenAccounts?: readonly string[];
  now?: number;
  allowRebalance?: boolean;
}): RotationDecision | undefined {
  const fresh = usages.filter(
    (usage) =>
      !usage.error &&
      Number.isFinite(usage.capturedAt) &&
      now >= usage.capturedAt &&
      now - usage.capturedAt <= MAX_USAGE_AGE_MS,
  );
  const active = fresh.find((usage) => usage.accountName === activeAccount);
  if (!active) return undefined;
  const shortRemaining = remaining(active, FIVE_HOURS, now);
  if (shortRemaining === undefined) return undefined;
  const weeklyRemaining = remaining(active, WEEK, now);
  const urgent =
    shortRemaining < 5 ||
    (weeklyRemaining !== undefined && weeklyRemaining <= 5);
  if (!urgent && !allowRebalance) return undefined;

  const hidden = new Set(hiddenAccounts);
  const candidates = fresh
    .filter(
      (usage) =>
        usage.accountName !== activeAccount &&
        !hidden.has(usage.accountName) &&
        (remaining(usage, FIVE_HOURS, now) ?? 0) > 5 &&
        (![usage.primary, usage.secondary].some(
          (window) => window?.windowSeconds === WEEK,
        ) ||
          (remaining(usage, WEEK, now) ?? 0) > 5),
    )
    .map((usage) => ({ usage, budget: weeklyBudget(usage, now) }))
    .sort((left, right) => {
      const tier = (budget: ReturnType<typeof weeklyBudget>) =>
        budget ? (budget.paced ? 2 : 1) : 0;
      return (
        tier(right.budget) - tier(left.budget) ||
        (right.budget?.rate ?? -1) - (left.budget?.rate ?? -1) ||
        left.usage.accountName.localeCompare(
          right.usage.accountName,
          undefined,
          { numeric: true },
        )
      );
    });
  const best = candidates[0];
  if (!best) return undefined;
  if (urgent)
    return { accountName: best.usage.accountName, reason: "low-quota" };
  const current = weeklyBudget(active, now);
  if (
    current &&
    best.budget?.paced &&
    (!current.paced || best.budget.rate > current.rate * 1.5)
  )
    return { accountName: best.usage.accountName, reason: "weekly-balance" };
  return undefined;
}
