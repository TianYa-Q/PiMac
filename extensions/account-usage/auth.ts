import {
  cleanupSessionResources,
  type OAuthCredential,
} from "@earendil-works/pi-ai";
import type { ExtensionContext } from "@earendil-works/pi-coding-agent";
import { getCodexOAuth } from "./oauth.js";
import { createAccountStore } from "./store.js";
import type { AccountProvider } from "./types.js";

const RUNTIME_AUTH_SELECTOR = "codex-account-manager";
const REFRESH_SKEW_MS = 5 * 60 * 1_000;

type RuntimeAuthStorage = {
  setRuntimeApiKey(providerId: string, apiKey: string): void | Promise<void>;
  removeRuntimeApiKey(providerId: string): void | Promise<void>;
};

type ProviderConfig = Parameters<
  ExtensionContext["modelRegistry"]["registerProvider"]
>[1];

/**
 * 为当前 Pi 进程应用会话绑定的 Codex 凭据。
 * 每个 Pi 进程拥有独立的运行时凭据，因此旧会话不会被其他进程中的全局账户切换影响。
 */
export class CodexSessionAuth {
  constructor(private readonly providerId: AccountProvider = "openai-codex") {}
  private previousProviderConfig: ProviderConfig | undefined;
  private ownsProviderOverlay = false;
  private appliedAccessToken: string | undefined;
  private previousRuntimeKey: string | undefined;

  async activate(
    ctx: ExtensionContext,
    accountName: string,
    signal: AbortSignal,
  ): Promise<void> {
    signal.throwIfAborted();
    const credential = await this.readFreshCredential(accountName, signal);
    signal.throwIfAborted();
    if (credential.access === this.appliedAccessToken) {
      const resolved = await ctx.modelRegistry.getApiKeyForProvider(
        this.providerId,
      );
      signal.throwIfAborted();
      if (resolved === credential.access) return;
    }

    const runtime = getRuntimeAuthStorage(ctx);
    if (!runtime) {
      throw new Error("当前 Pi 版本不支持运行时切换 Codex 凭据。");
    }

    if (!this.ownsProviderOverlay) {
      const runtimeStatus = (
        runtime as RuntimeAuthStorage & {
          getProviderAuthStatus?: (id: string) => { source?: string };
        }
      ).getProviderAuthStatus?.(this.providerId);
      if (runtimeStatus?.source === "runtime") {
        this.previousRuntimeKey = await ctx.modelRegistry.getApiKeyForProvider(
          this.providerId,
        );
      }
      signal.throwIfAborted();
      this.previousProviderConfig =
        ctx.modelRegistry.getRegisteredProviderConfig(this.providerId);
      ctx.modelRegistry.registerProvider(this.providerId, {
        apiKey: RUNTIME_AUTH_SELECTOR,
      });
      this.ownsProviderOverlay = true;
    }

    await runtime.setRuntimeApiKey(this.providerId, credential.access);
    const resolved = await ctx.modelRegistry.getApiKeyForProvider(
      this.providerId,
    );
    if (resolved !== credential.access) {
      throw new Error(`Pi 未能应用 Codex 账户 ${accountName} 的运行时凭据。`);
    }

    await cleanupSessionResources(ctx.sessionManager.getSessionId());
    this.appliedAccessToken = credential.access;
  }

  async clear(ctx: ExtensionContext): Promise<void> {
    const runtime = getRuntimeAuthStorage(ctx);
    // Never remove another extension's or --api-key's runtime credential if we
    // did not install this overlay. Restore a preexisting runtime key on exit.
    if (runtime && this.ownsProviderOverlay) {
      if (this.previousRuntimeKey)
        await runtime.setRuntimeApiKey(
          this.providerId,
          this.previousRuntimeKey,
        );
      else await runtime.removeRuntimeApiKey(this.providerId);
    }

    if (this.ownsProviderOverlay) {
      ctx.modelRegistry.unregisterProvider(this.providerId);
      if (this.previousProviderConfig) {
        ctx.modelRegistry.registerProvider(
          this.providerId,
          this.previousProviderConfig,
        );
      }
    }

    this.previousProviderConfig = undefined;
    this.ownsProviderOverlay = false;
    this.appliedAccessToken = undefined;
    this.previousRuntimeKey = undefined;
  }

  private async readFreshCredential(
    accountName: string,
    signal: AbortSignal,
  ): Promise<OAuthCredential> {
    const store = createAccountStore(this.providerId);
    const account = store
      .readCodexAccountState()
      .accounts.find((candidate) => candidate.name === accountName);
    if (!account) throw new Error(`Codex 账户 ${accountName} 不存在。`);
    if (account.credential.expires > Date.now() + REFRESH_SKEW_MS) {
      return account.credential;
    }

    return store.refreshStoredCredential(accountName, async (latest) => {
      signal.throwIfAborted();
      const refreshed = await getCodexOAuth(this.providerId).refresh(
        latest,
        signal,
      );
      signal.throwIfAborted();
      return { ...latest, ...refreshed };
    });
  }
}

function getRuntimeAuthStorage(
  ctx: ExtensionContext,
): RuntimeAuthStorage | undefined {
  const registry = ctx.modelRegistry as unknown as {
    runtime?: unknown;
    authStorage?: unknown;
  };
  for (const candidate of [registry, registry.runtime, registry.authStorage]) {
    if (isRuntimeAuthStorage(candidate)) return candidate;
  }
  return undefined;
}

function isRuntimeAuthStorage(value: unknown): value is RuntimeAuthStorage {
  return (
    typeof value === "object" &&
    value !== null &&
    "setRuntimeApiKey" in value &&
    typeof value.setRuntimeApiKey === "function" &&
    "removeRuntimeApiKey" in value &&
    typeof value.removeRuntimeApiKey === "function"
  );
}
