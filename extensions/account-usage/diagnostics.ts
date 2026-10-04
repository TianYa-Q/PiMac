import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { describeQuotaError } from "./diagnostic-error.js";
import { appendPrivateDiagnostic } from "./private-log.js";

// Failures only; never write OAuth credentials, request headers, URLs or response bodies.
// Keep the current log and one rotated backup (roughly 2 MiB total).
const LOG_PATH = join(getAgentDir(), "account-usage-errors.jsonl");

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
