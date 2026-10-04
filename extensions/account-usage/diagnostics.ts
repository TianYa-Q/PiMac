import {
  appendFileSync,
  chmodSync,
  mkdirSync,
  renameSync,
  statSync,
} from "node:fs";
import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { describeQuotaError } from "./diagnostic-error.js";

// Failures only; never write OAuth credentials, request headers, URLs or response bodies.
// Keep the current log and one rotated backup (roughly 2 MiB total).
const LOG_PATH = join(getAgentDir(), "account-usage-errors.jsonl");
const MAX_LOG_BYTES = 1024 * 1024;

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
    mkdirSync(getAgentDir(), { recursive: true, mode: 0o700 });
    try {
      if (statSync(LOG_PATH).size >= MAX_LOG_BYTES)
        renameSync(LOG_PATH, `${LOG_PATH}.1`);
    } catch (fileError) {
      if (
        !(
          fileError instanceof Error &&
          "code" in fileError &&
          fileError.code === "ENOENT"
        )
      ) {
        throw fileError;
      }
    }
    appendFileSync(
      LOG_PATH,
      `${JSON.stringify({ timestamp: new Date().toISOString(), pid: process.pid, ...context, error: describeQuotaError(error) })}\n`,
      {
        encoding: "utf8",
        mode: 0o600,
      },
    );
    chmodSync(LOG_PATH, 0o600);
  } catch {
    // Diagnostics must never break quota refreshes.
  }
}
