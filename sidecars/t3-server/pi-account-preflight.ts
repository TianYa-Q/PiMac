type AccountSampler = {
  accountStatus(input: { provider: string; force: boolean }): Promise<unknown>;
};

/** 额度仍由宿主管理；在 Pi prompt 之前等待采样落盘，避免首轮与后台 tick 竞态。
 * 使用宿主原有缓存/同 provider single-flight，不强制每条消息请求网络，也不在 Pi 扩展内采样。
 * 只处理真实订阅 provider；虚拟路由、其他 provider 保持原行为。
 */
export async function preparePiAccountQuota(
  model: unknown,
  accounts: AccountSampler | undefined,
): Promise<void> {
  if (!model || typeof model !== "object" || !("provider" in model)) return;
  if (model.provider !== "openai" && model.provider !== "openai-codex") return;
  if ("api" in model && model.api === "pi-virtual") return;
  if (!accounts) return;
  await accounts.accountStatus({ provider: model.provider, force: false });
}
