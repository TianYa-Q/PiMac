import type { AccountProvider, AccountUsage, UsageWindow } from "./types.js";
import { sampleFreshness } from "./freshness.js";
import { formatUsageSummary } from "./format.js";

function windowSnapshot(window: UsageWindow | undefined) {
  if (!window) return undefined;
  return {
    remainingPercent: window.remainingPercent,
    resetAt: window.resetAt,
    windowSeconds: window.windowSeconds,
  };
}

/** Caller supplies only visible, identity-matched telemetry. Never serialize raw errors
 * or spread provider objects: export is an explicit, credential-free allowlist.
 */
export function buildCachedReport(options: {
  provider: AccountProvider;
  visibleNames: readonly string[];
  usages: readonly AccountUsage[];
  activeAccount: string | undefined;
  now: number;
  maxAgeMs: number;
}) {
  const byName = new Map(
    options.usages.map((usage) => [usage.accountName, usage]),
  );
  return {
    version: 1,
    provider: options.provider,
    generatedAt: options.now,
    source: "session-cache",
    accounts: [...new Set(options.visibleNames)].map((name) => {
      const usage = byName.get(name);
      return {
        name,
        active: name === options.activeAccount,
        status: !usage ? "missing" : usage.error ? "failed" : "available",
        freshness: sampleFreshness(
          usage?.capturedAt,
          options.now,
          options.maxAgeMs,
        ),
        capturedAt: usage?.capturedAt,
        primary: usage?.error ? undefined : windowSnapshot(usage?.primary),
        secondary: usage?.error ? undefined : windowSnapshot(usage?.secondary),
      };
    }),
  };
}

/** RFC 4180 cells plus spreadsheet formula neutralization for untrusted names.
 * Always quote text, including commas/newlines; numeric telemetry stays numeric.
 */
function csvCell(value: string | number | boolean | undefined): string {
  if (value === undefined) return "";
  if (typeof value !== "string") return String(value);
  // Leading control characters are deliberately covered: spreadsheet importers
  // may strip them before interpreting a formula.
  // eslint-disable-next-line no-control-regex
  const safe = /^[\s\u0000-\u001f]*[=+\-@]/u.test(value) ? "'" + value : value;
  return '"' + safe.replaceAll('"', '""') + '"';
}

/** Same allowlist and visibility policy as JSON; no file or network side effects. */
export function formatCachedCSV(
  report: ReturnType<typeof buildCachedReport>,
): string {
  const header = [
    "provider",
    "generated_at_ms",
    "account",
    "active",
    "status",
    "freshness",
    "captured_at_ms",
    "primary_remaining_percent",
    "primary_reset_at_s",
    "primary_window_seconds",
    "secondary_remaining_percent",
    "secondary_reset_at_s",
    "secondary_window_seconds",
  ];
  return (
    [
      header.join(","),
      ...report.accounts.map((account) =>
        [
          report.provider,
          report.generatedAt,
          account.name,
          account.active,
          account.status,
          account.freshness,
          account.capturedAt,
          account.primary?.remainingPercent,
          account.primary?.resetAt,
          account.primary?.windowSeconds,
          account.secondary?.remainingPercent,
          account.secondary?.resetAt,
          account.secondary?.windowSeconds,
        ]
          .map(csvCell)
          .join(","),
      ),
    ].join("\r\n") + "\r\n"
  );
}

export function formatCachedReport(
  report: ReturnType<typeof buildCachedReport>,
  usages: readonly AccountUsage[],
  activeAccount: string | undefined,
  maxAgeMs: number,
): string {
  const visible = new Set(report.accounts.map((account) => account.name));
  const snapshots = usages.filter((usage) => visible.has(usage.accountName));
  return [
    "当前会话的额度缓存（不请求网络／不预热／不切换账户）",
    ...(snapshots.length
      ? [
          formatUsageSummary(
            snapshots,
            activeAccount,
            report.generatedAt,
            maxAgeMs,
          ),
        ]
      : []),
    ...report.accounts
      .filter((account) => account.status === "missing")
      .map((account) => `账户 ${account.name}：暂无有效快照`),
    ...(report.accounts.length ? [] : ["没有可显示的账户；隐藏账户不会显示。"]),
    "运行 /usage refresh 获取最新额度；后台自动刷新仍按原有周期运行。",
  ].join("\n");
}
