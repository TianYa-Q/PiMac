import { createHash } from "node:crypto";
import type { OAuthCredential } from "@earendil-works/pi-ai";
import type { CodexAccount } from "./types.js";

/** Resolve metadata or JWT claims without exporting tokens to cache keys or UI. */
export function resolveAccountId(
  credential: OAuthCredential,
): string | undefined {
  const value = credential as OAuthCredential & { accountId?: unknown };
  if (typeof value.accountId === "string" && value.accountId.trim())
    return value.accountId;
  const payload = credential.access.split(".")[1];
  if (!payload || payload.length > 64 * 1024) return undefined;
  try {
    const decoded = JSON.parse(
      Buffer.from(payload, "base64url").toString("utf8"),
    ) as unknown;
    if (
      typeof decoded !== "object" ||
      decoded === null ||
      Array.isArray(decoded)
    )
      return undefined;
    const auth = (decoded as Record<string, unknown>)[
      "https://api.openai.com/auth"
    ];
    if (typeof auth !== "object" || auth === null || Array.isArray(auth))
      return undefined;
    const id = (auth as Record<string, unknown>).chatgpt_account_id;
    return typeof id === "string" && id.trim() ? id : undefined;
  } catch {
    return undefined;
  }
}

/** Names alone are not identity: a replaced login must never inherit old quota.
 * Stable account IDs survive token refresh; opaque grants conservatively invalidate.
 * Only a digest is persisted, not IDs, access tokens or refresh tokens.
 */
export function accountUsageCacheKey(
  accounts: readonly CodexAccount[],
): string {
  const identities = accounts.map((account) => [
    account.provider ?? "openai-codex",
    account.name,
    resolveAccountId(account.credential) ?? account.credential.access,
  ]);
  identities.sort((a, b) => JSON.stringify(a).localeCompare(JSON.stringify(b)));
  return `identity-v1:${createHash("sha256").update(JSON.stringify(identities)).digest("hex")}`;
}
