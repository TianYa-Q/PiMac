import type { OAuthAuth } from "@earendil-works/pi-ai";
import { builtinProviders } from "@earendil-works/pi-ai/providers/all";
import type { AccountProvider } from "./types.js";

/** 会话认证只复用官方刷新实现；交互登录由 PiMac 宿主负责。 */
export function getCodexOAuth(
  providerId: AccountProvider = "openai-codex",
): OAuthAuth {
  const oauth = builtinProviders().find(
    (provider) => provider.id === providerId,
  )?.auth.oauth;
  if (!oauth) throw new Error(`Pi 内置的 ${providerId} OAuth 不可用。`);
  return oauth;
}
