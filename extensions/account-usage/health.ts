import type { AccountProvider, AccountUsage } from "./types.js";

/** Read-only snapshot diagnostics. Never accept credentials or include provider errors. */
export function formatUsageHealth(options: {
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
}): string {
  const now = options.now ?? Date.now();
  const hidden = new Set(options.hiddenNames);
  const visible = options.accountNames.filter((name) => !hidden.has(name));
  const usages = new Map(
    options.usages.map((usage) => [usage.accountName, usage]),
  );
  let fresh = 0,
    stale = 0,
    failed = 0,
    missing = 0;
  for (const name of visible) {
    const usage = usages.get(name);
    if (!usage) missing++;
    else if (usage.error !== undefined) failed++;
    else if (!usage.primary && !usage.secondary) missing++;
    else if (
      !Number.isFinite(usage.capturedAt) ||
      usage.capturedAt > now ||
      now - usage.capturedAt >= options.maxAgeMs
    )
      stale++;
    else fresh++;
  }
  const gemini = {
    unconfigured: "未配置",
    loaded: "已加载快照",
    failed: "查询失败",
  }[options.gemini];
  return [
    "账户额度健康检查（只读，不请求网络／不预热／不切换账户）",
    `Provider：${options.provider}`,
    `认证：${options.authFailed ? "激活失败，下次运行前需修复" : options.managed ? "扩展托管 OAuth" : "未托管，自动轮换不适用"}`,
    `账户：${options.accountNames.length} · 可见 ${visible.length} · 隐藏 ${options.accountNames.length - visible.length}`,
    `额度：新鲜 ${fresh} · 过期 ${stale} · 失败 ${failed} · 未知 ${missing}`,
    `刷新：${options.refreshing ? "进行中" : "空闲"}`,
    `Gemini：${gemini}（不代表实时连通）`,
    "恢复：/usage refresh 重新查询；/accounts 管理登录；/usage settings 检查隐藏设置。",
    "诊断日志：agent 目录下 account-usage-errors.jsonl（不包含凭据或响应正文）。",
  ].join("\n");
}
