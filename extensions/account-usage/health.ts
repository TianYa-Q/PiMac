import type { AccountProvider, AccountUsage } from "./types.js";

export type UsageHealthOptions = {
  provider: AccountProvider;
  managed: boolean;
  authFailed: boolean;
  accountNames: readonly string[];
  hiddenNames: readonly string[];
  usages: readonly AccountUsage[];
  maxAgeMs: number;
  gemini: "unconfigured" | "loaded" | "failed";
  refreshing: boolean;
  now?: number;
};

/** Versioned, read-only diagnostics. Contains counts, never account names or errors. */
export function buildUsageHealthReport(options: UsageHealthOptions) {
  const now = options.now ?? Date.now();
  const hidden = new Set(options.hiddenNames);
  const visible = options.accountNames.filter((name) => !hidden.has(name));
  const usages = new Map(
    options.usages.map((usage) => [usage.accountName, usage]),
  );
  const snapshots = { fresh: 0, stale: 0, failed: 0, missing: 0 };
  for (const name of visible) {
    const usage = usages.get(name);
    if (!usage) snapshots.missing++;
    else if (usage.error !== undefined) snapshots.failed++;
    else if (!usage.primary && !usage.secondary) snapshots.missing++;
    else if (
      !Number.isFinite(usage.capturedAt) ||
      usage.capturedAt > now ||
      now - usage.capturedAt >= options.maxAgeMs
    )
      snapshots.stale++;
    else snapshots.fresh++;
  }
  return {
    version: 1,
    provider: options.provider,
    auth: options.authFailed
      ? "failed"
      : options.managed
        ? "managed"
        : "unmanaged",
    accounts: {
      total: options.accountNames.length,
      visible: visible.length,
      hidden: options.accountNames.length - visible.length,
    },
    snapshots,
    refreshing: options.refreshing,
    gemini: options.gemini,
  };
}

export function formatUsageHealth(options: UsageHealthOptions): string {
  const report = buildUsageHealthReport(options);
  const gemini = {
    unconfigured: "未配置",
    loaded: "已加载快照",
    failed: "查询失败",
  }[report.gemini];
  const { fresh, stale, failed, missing } = report.snapshots;
  return [
    "账户额度健康检查（只读，不请求网络／不预热／不切换账户）",
    `Provider：${report.provider}`,
    `认证：${report.auth === "failed" ? "激活失败，下次运行前需修复" : report.auth === "managed" ? "扩展托管 OAuth" : "未托管，自动轮换不适用"}`,
    `账户：${report.accounts.total} · 可见 ${report.accounts.visible} · 隐藏 ${report.accounts.hidden}`,
    `额度：新鲜 ${fresh} · 过期 ${stale} · 失败 ${failed} · 未知 ${missing}`,
    `刷新：${report.refreshing ? "进行中" : "空闲"}`,
    `Gemini：${gemini}（不代表实时连通）`,
    "恢复：/usage refresh 重新查询；/accounts 管理登录；/usage settings 检查隐藏设置。",
    "诊断日志：agent 目录下 account-usage-errors.jsonl（不包含凭据或响应正文）。",
  ].join("\n");
}
