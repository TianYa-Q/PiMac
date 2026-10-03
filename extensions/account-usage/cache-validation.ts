import type { AccountUsage } from "./types.js";

function record(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function optionalNumber(value: unknown): boolean {
  return (
    value === undefined ||
    (typeof value === "number" && Number.isFinite(value) && value >= 0)
  );
}

function window(value: unknown): boolean {
  return (
    value === undefined ||
    (record(value) &&
      typeof value.remainingPercent === "number" &&
      Number.isFinite(value.remainingPercent) &&
      value.remainingPercent >= 0 &&
      value.remainingPercent <= 100 &&
      optionalNumber(value.resetAt) &&
      optionalNumber(value.windowSeconds))
  );
}

/** Disk JSON is not trusted telemetry. Reject the complete snapshot rather than rotate on a subset. */
export function validAccountUsages(
  value: unknown,
  names: readonly string[],
): value is AccountUsage[] {
  if (!Array.isArray(value) || value.length !== names.length) return false;
  const expected = new Set(names);
  return value.every((usage: unknown) => {
    if (
      !record(usage) ||
      typeof usage.accountName !== "string" ||
      !expected.delete(usage.accountName) ||
      typeof usage.capturedAt !== "number" ||
      !optionalNumber(usage.capturedAt) ||
      !window(usage.primary) ||
      !window(usage.secondary) ||
      (usage.error !== undefined && typeof usage.error !== "string")
    )
      return false;
    const credits = usage.resetCredits;
    return (
      credits === undefined ||
      (record(credits) &&
        Number.isSafeInteger(credits.availableCount) &&
        (credits.availableCount as number) >= 0 &&
        Array.isArray(credits.credits) &&
        credits.credits.every(
          (credit: unknown) =>
            record(credit) &&
            optionalNumber(credit.expiresAt) &&
            (credit.title === undefined || typeof credit.title === "string"),
        ))
    );
  });
}
