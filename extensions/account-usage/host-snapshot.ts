import { join } from "node:path";
import { getAgentDirectory } from "./agent-directory.js";
import { accountUsageCacheKey } from "./account-identity.js";
import { validAccountUsages } from "./cache-validation.js";
import { readPrivateRegularFile, writePrivateJson } from "./private-json.js";
import type { AccountProvider, AccountUsage, CodexAccount } from "./types.js";

/** 额度由 PiMac 采样；会话只读取与当前账户身份匹配的快照，绝不发起网络查询或激活。 */
export function readHostSnapshot(
  provider: AccountProvider,
  accounts: readonly CodexAccount[],
  directory: string = getAgentDirectory(),
): AccountUsage[] {
  let document: unknown;
  try {
    document = JSON.parse(
      readPrivateRegularFile(snapshotPath(provider, directory)),
    );
  } catch (error) {
    if (error instanceof Error && "code" in error && error.code === "ENOENT")
      return [];
    throw error;
  }
  if (
    !document ||
    typeof document !== "object" ||
    !("version" in document) ||
    document.version !== 1 ||
    !("key" in document) ||
    !("usages" in document)
  ) {
    throw new Error("PiMac 额度快照格式无效。");
  }
  if (document.key !== accountUsageCacheKey(accounts)) return [];
  if (
    !validAccountUsages(
      document.usages,
      accounts.map((account) => account.name),
    )
  ) {
    throw new Error("PiMac 额度快照数据无效。");
  }
  return document.usages;
}

export function writeHostSnapshot(
  provider: AccountProvider,
  accounts: readonly CodexAccount[],
  usages: AccountUsage[],
  directory: string,
): void {
  if (
    !validAccountUsages(
      usages,
      accounts.map((account) => account.name),
    )
  ) {
    throw new Error("拒绝保存无效的 PiMac 额度快照。");
  }
  writePrivateJson(snapshotPath(provider, directory), {
    version: 1,
    key: accountUsageCacheKey(accounts),
    usages,
  });
}

function snapshotPath(provider: AccountProvider, directory: string): string {
  return join(directory, `pimac-${provider}-quota.json`);
}
