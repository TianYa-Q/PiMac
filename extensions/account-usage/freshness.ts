/** Shared sample-age policy; publication time is never a substitute for capture time. */
export function sampleFreshness(
  capturedAt: number | undefined,
  now: number,
  maxAgeMs: number,
): "fresh" | "stale" | "future" | "unknown" {
  if (
    capturedAt === undefined ||
    !Number.isFinite(capturedAt) ||
    capturedAt < 0
  )
    return "unknown";
  if (!Number.isFinite(now) || !Number.isFinite(maxAgeMs) || maxAgeMs <= 0)
    return "unknown";
  if (capturedAt > now) return "future";
  return now - capturedAt >= maxAgeMs ? "stale" : "fresh";
}

export function sampleAgeLabel(
  capturedAt: number | undefined,
  now: number,
  maxAgeMs: number,
): string {
  const freshness = sampleFreshness(capturedAt, now, maxAgeMs);
  if (freshness === "unknown") return "采样时间未知";
  if (freshness === "future") return "采样时间超前，请检查系统时钟";
  const seconds = Math.floor((now - capturedAt!) / 1_000);
  const age =
    seconds < 60 ? `${seconds} 秒前` : `${Math.floor(seconds / 60)} 分钟前`;
  return `${age}${freshness === "stale" ? " · 已过期" : ""}`;
}
