import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { describeQuotaError } from "./diagnostic-error.js";
import { appendPrivateDiagnostic } from "./private-log.js";
import type { AccountProvider } from "./types.js";

// Failures only; never write OAuth credentials, request headers, URLs or response bodies.
// Keep the current log and one rotated backup (roughly 2 MiB total).
const LOG_PATH = join(getAgentDir(), "account-usage-errors.jsonl");

/** 只记录认证阶段和会话关联信息；原始异常可能包含凭据或路径，必须走白名单。 */
export function logAccountAuthFailure(
  context: {
    provider: AccountProvider;
    operation: "read_state" | "initialize" | "activate" | "block_run";
    sessionId: string;
  },
  error: unknown,
): void {
  try {
    appendPrivateDiagnostic(LOG_PATH, {
      timestamp: new Date().toISOString(),
      pid: process.pid,
      source: "account-usage",
      category: "account_auth",
      provider: context.provider,
      operation: context.operation,
      sessionId: /^[a-zA-Z0-9._:-]{1,128}$/u.test(context.sessionId)
        ? context.sessionId
        : undefined,
      error: error === undefined ? undefined : describeQuotaError(error),
    });
  } catch {
    // 诊断不可改变认证结果，也不可阻止取消失败的请求。
  }
}

export function logQuotaFailure(
  context: {
    provider: "codex" | "gemini" | "shared";
    operation: string;
    accountName?: string;
    elapsedMs: number;
  },
  error: unknown,
): void {
  try {
    appendPrivateDiagnostic(LOG_PATH, {
      timestamp: new Date().toISOString(),
      pid: process.pid,
      provider: context.provider,
      operation: context.operation.slice(0, 128),
      accountName: context.accountName?.slice(0, 256),
      elapsedMs: Number.isFinite(context.elapsedMs)
        ? Math.max(0, Math.round(context.elapsedMs))
        : undefined,
      error: describeQuotaError(error),
    });
  } catch {
    // Diagnostics must never break quota refreshes.
  }
}
