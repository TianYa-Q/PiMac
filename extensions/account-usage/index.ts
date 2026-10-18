import {
  SessionManager,
  type ExtensionAPI,
  type ExtensionCommandContext,
  type ExtensionContext,
  type SessionStartEvent,
} from "@earendil-works/pi-coding-agent";
import { CodexSessionAuth } from "./auth.js";
import { logAccountAuthFailure } from "./diagnostics.js";
import { readHostSnapshot } from "./host-snapshot.js";
import { nextAccount, REBALANCE_COOLDOWN_MS } from "./rotation.js";
import { createAccountStore } from "./store.js";
import {
  accountProvider,
  type AccountProvider,
  type AccountUsage,
  type CodexAccountState,
  type UsageSettings,
} from "./types.js";

const STATUS_KEY = "account-usage";
const GUI_STATUS_KEY = "account-usage-gui";
const SELECTION_ENTRY_TYPE = "codex-account-selection";
const LEGACY_SELECTION_ENTRY_TYPE = "pi-accounts-selection";
const MODEL_HANDOFF_ENTRY_TYPE = "model-handoff-on-new-session";
type SelectionEntryData = {
  version: 1;
  sessionId: string;
  accountName: string;
  provider: AccountProvider;
};

/** Pi 扩展仅负责会话执行边界；账户管理、采样与激活均由 PiMac 宿主拥有。 */
export default function codexAccountExtension(pi: ExtensionAPI) {
  let settings: UsageSettings = { version: 1, hiddenAccounts: [] };
  let usages = new Map<string, AccountUsage>();
  let sessionActive = false;
  let sessionAccount: string | undefined;
  let authFailed = false;
  let sessionController: AbortController | undefined;
  let providerId: AccountProvider = "openai-codex";
  let accountStore = createAccountStore(providerId);
  let sessionAuth = new CodexSessionAuth(providerId);
  let managesSelectedAuth = false;
  let rotationInFlight: Promise<boolean> | undefined;
  let lastRebalanceAt = 0;
  let lastFailedRotationAt = 0;
  let automaticRetryUsed = false;
  const safeReadAccountState = (ctx: ExtensionContext) =>
    readAccountStateSafely(ctx, providerId);
  const accountContextGuard = (store: typeof accountStore) => {
    const owner = sessionController;
    return () => {
      if (
        !sessionActive ||
        store !== accountStore ||
        owner !== sessionController ||
        owner?.signal.aborted
      )
        throw new Error("账户管理会话或模型 provider 已变更，请重新执行命令。");
    };
  };
  const usagesForState = (state: CodexAccountState): AccountUsage[] => {
    const visible = state.accounts.filter(
      (account) => !settings.hiddenAccounts.includes(account.name),
    );
    // readHostSnapshot 再核对完整身份；同名替换登录不能继承旧额度。
    const snapshot = readHostSnapshot(providerId, visible);
    usages = new Map(snapshot.map((usage) => [usage.accountName, usage]));
    return [...usages.values()];
  };
  const publishStatus = (ctx: ExtensionContext) => {
    const state = safeReadAccountState(ctx);
    if (!state) return;
    ctx.ui.setStatus(
      GUI_STATUS_KEY,
      JSON.stringify({
        version: 2,
        provider: providerId,
        selectionOnly: true,
        supportsAccountSwitch:
          ctx.model?.provider === providerId && ctx.model.api !== "pi-virtual",
        managesSelectedAuth,
        activeAccount: managesSelectedAuth ? sessionAccount : undefined,
        defaultAccount: state.activeAccount,
        accounts: [],
        updatedAt: Date.now(),
      }),
    );
  };
  const refreshAll = async (
    ctx: ExtensionContext,
    _notify: boolean,
    _force = false,
    rotateIdle = true,
  ) => {
    const state = safeReadAccountState(ctx);
    if (!state) return;
    try {
      settings = accountStore.readSettings();
      usagesForState(state);
      if (rotateIdle) await rotateAccounts(ctx);
    } catch (error) {
      usages.clear();
      ctx.ui.notify(
        `读取 PiMac 额度快照失败：${errorMessage(error)}`,
        "warning",
      );
    }
    publishStatus(ctx);
  };
  const activateForSession = async (
    ctx: ExtensionContext,
    accountName: string,
  ) => {
    const signal = sessionController?.signal;
    if (!signal) throw new Error("账户管理会话尚未初始化。");
    const auth = sessionAuth;
    try {
      await auth.activate(ctx, accountName, signal);
      signal.throwIfAborted();
      if (auth === sessionAuth) authFailed = false;
    } catch (error) {
      if (auth === sessionAuth) authFailed = true;
      logAccountAuthFailure(
        {
          provider: providerId,
          operation: "activate",
          sessionId: ctx.sessionManager.getSessionId(),
        },
        error,
      );
      throw error;
    }
  };

  // Automatic changes are session-local. Manual /accounts switch still changes
  // the future default. Never abort tools or inject/replay a user's prompt.
  const rotateAccounts = async (
    ctx: ExtensionContext,
    boundary = false,
    allowRebalance = true,
    confirmedQuotaFailure = false,
  ): Promise<boolean> => {
    if (rotationInFlight) await rotationInFlight;
    const signal = sessionController?.signal;
    const store = accountStore;
    const auth = sessionAuth;
    const previous = sessionAccount;
    const canCommit = () =>
      sessionActive &&
      !!signal &&
      !signal.aborted &&
      store === accountStore &&
      auth === sessionAuth &&
      managesSelectedAuth &&
      sessionAccount === previous &&
      ctx.model?.provider === providerId &&
      ctx.model.api !== "pi-virtual";
    const safeBoundary = () =>
      canCommit() && (ctx.isIdle() || (boundary && !ctx.signal?.aborted));
    if (
      !previous ||
      !safeBoundary() ||
      Date.now() - lastFailedRotationAt < 60_000
    )
      return false;
    const state = safeReadAccountState(ctx);
    if (!state) return false;
    let snapshot: AccountUsage[];
    try {
      settings = store.readSettings();
      snapshot = usagesForState(state);
    } catch (error) {
      usages.clear();
      ctx.ui.notify(
        `读取 PiMac 额度快照失败：${errorMessage(error)}`,
        "warning",
      );
      return false;
    }
    const decision = nextAccount({
      activeAccount: previous,
      confirmedQuotaFailure,
      usages: snapshot.filter((usage) =>
        state.accounts.some((account) => account.name === usage.accountName),
      ),
      hiddenAccounts: settings.hiddenAccounts,
      allowRebalance:
        allowRebalance && Date.now() - lastRebalanceAt >= REBALANCE_COOLDOWN_MS,
    });
    if (!decision) return false;
    const task = (async () => {
      try {
        await auth.activate(ctx, decision.accountName, signal!, safeBoundary);
        if (!canCommit()) return false;
        persistSessionSelection(pi, ctx, decision.accountName, providerId);
        sessionAccount = decision.accountName;
        authFailed = false;
        lastRebalanceAt = Date.now();
        publishStatus(ctx);
        ctx.ui.notify(
          `已自动切换到 ${decision.accountName}（${decision.reason === "low-quota" ? "账户额度不足" : "周额度负载平衡"}）；仅影响当前会话。`,
          "info",
        );
        return true;
      } catch (error) {
        if (!canCommit()) return false; // Shutdown/provider replacement owns cleanup.
        lastFailedRotationAt = Date.now();
        try {
          await auth.activate(ctx, previous, signal!);
          persistSessionSelection(pi, ctx, previous, providerId);
          authFailed = false;
        } catch {
          authFailed = true;
        }
        ctx.ui.notify(
          `自动切换账户失败，未自动续跑：${errorMessage(error)}`,
          "warning",
        );
        return false;
      }
    })();
    rotationInFlight = task;
    try {
      return await task;
    } finally {
      if (rotationInFlight === task) rotationInFlight = undefined;
    }
  };

  const switchAccount = async (
    ctx: ExtensionCommandContext,
    accountName: string,
  ) => {
    const store = accountStore;
    const assertCurrent = accountContextGuard(store);
    if (rotationInFlight) await rotationInFlight;
    assertCurrent();
    if (!ctx.isIdle()) throw new Error("请先停止当前任务再切换账户。");
    lastRebalanceAt = Date.now(); // Respect an explicit choice; urgency can override it.
    await activateForSession(ctx, accountName);
    assertCurrent();
    managesSelectedAuth = true;
    persistSessionSelection(pi, ctx, accountName, providerId);
    sessionAccount = accountName;
    publishStatus(ctx);
    await refreshAll(ctx, false);
    ctx.ui.notify(
      `已切换到 ${accountName}。仅当前会话使用该账户；新会话默认由 PiMac 管理。`,
      "info",
    );
  };

  pi.registerCommand("accounts", {
    description: "切换当前会话账户；登录、默认账户和额度管理请使用 PiMac",
    handler: async (args, ctx) => {
      const match = args.trim().match(/^switch\s+([A-Za-z0-9._-]{1,64})$/u);
      if (!match?.[1]) {
        ctx.ui.notify(
          "账户管理已迁至 PiMac；会话内仅支持 /accounts switch <账户名>。",
          "info",
        );
        return;
      }
      const state = safeReadAccountState(ctx);
      if (!state) return;
      requireExistingAccount(state, match[1]);
      await switchAccount(ctx, match[1]);
    },
  });
  pi.on("session_before_switch", (event, ctx) => {
    if (event.reason === "new" && ctx.model)
      pi.appendEntry(MODEL_HANDOFF_ENTRY_TYPE, {
        provider: ctx.model.provider,
        modelId: ctx.model.id,
      });
  });
  const initializeAccounts = async (ctx: ExtensionContext) => {
    providerId = accountProvider(ctx.model?.provider);
    accountStore = createAccountStore(providerId);
    sessionAuth = new CodexSessionAuth(providerId);
    managesSelectedAuth = false;
    authFailed = false;
    sessionAccount = undefined;
    usages.clear();
    lastRebalanceAt = 0;
    lastFailedRotationAt = 0;
    automaticRetryUsed = false;
    try {
      settings = accountStore.readSettings();
    } catch (error) {
      ctx.ui.notify(errorMessage(error), "error");
      settings = { version: 1, hiddenAccounts: [] };
    }

    const state = safeReadAccountState(ctx);
    if (state) {
      try {
        const bound = restoreSessionAccount(ctx, state, providerId, false);
        // Keep API keys unless this session explicitly chose a managed subscription.
        const model = ctx.model;
        const protectedAPIKey =
          model?.provider === providerId &&
          ctx.modelRegistry.hasConfiguredAuth(model) &&
          !ctx.modelRegistry.isUsingOAuth(model);
        sessionAccount =
          bound ?? (protectedAPIKey ? undefined : state.activeAccount);
        if (sessionAccount) {
          persistSessionSelection(pi, ctx, sessionAccount, providerId);
          await activateForSession(ctx, sessionAccount);
          managesSelectedAuth = true;
        } else {
          authFailed = providerId === "openai-codex" && !protectedAPIKey;
          if (authFailed)
            ctx.ui.notify(
              "尚未配置 Codex 账户，请在 PiMac 中登录。",
              "warning",
            );
        }
      } catch (error) {
        sessionAccount = undefined;
        authFailed = true;
        logAccountAuthFailure(
          {
            provider: providerId,
            operation: "initialize",
            sessionId: ctx.sessionManager.getSessionId(),
          },
          error,
        );
        ctx.ui.notify(errorMessage(error), "error");
      }
    } else {
      sessionAccount = undefined;
      authFailed = true;
    }
  };

  pi.on("session_start", async (event, ctx) => {
    sessionActive = true;
    sessionController = new AbortController();
    await initializeAccounts(ctx);
    await restoreModelForNewSession(pi, event, ctx);

    await refreshAll(ctx, false);
  });

  pi.on("model_select", async (_event, ctx) => {
    if (accountProvider(ctx.model?.provider) !== providerId) {
      sessionController?.abort();
      sessionController = new AbortController();
      if (rotationInFlight) await rotationInFlight;
      await sessionAuth.clear(ctx);
      await initializeAccounts(ctx);
      await refreshAll(ctx, false);
    }
    publishStatus(ctx);
  });

  pi.on("before_agent_start", async (_event, ctx) => {
    automaticRetryUsed = false;
    // 启动读取/激活失败时还没有托管绑定，旧逻辑会永久跳过认证并在每轮 abort。
    // 仅在新运行边界重试一次；数据仍损坏或凭据仍无效时继续由认证守卫阻止请求。
    if (authFailed && !managesSelectedAuth) {
      await sessionAuth.clear(ctx);
      await initializeAccounts(ctx);
    }
    await rotateAccounts(ctx, true);
    if (ctx.model?.provider !== providerId || ctx.model.api === "pi-virtual")
      return;
    if (!managesSelectedAuth) return;
    if (!sessionAccount) {
      authFailed = true;
      ctx.ui.notify("没有可用的 Codex 账户，请运行 /accounts。", "error");
      return;
    }
    try {
      await activateForSession(ctx, sessionAccount);
    } catch (error) {
      ctx.ui.notify(errorMessage(error), "error");
    }
  });

  pi.on("turn_start", (_event, ctx) => {
    if (
      ctx.model?.provider === providerId &&
      ctx.model.api !== "pi-virtual" &&
      authFailed
    ) {
      // Pi 的 cancelled 信号并不区分用户停止和扩展主动取消，单独保留取消来源。
      logAccountAuthFailure(
        {
          provider: providerId,
          operation: "block_run",
          sessionId: ctx.sessionManager.getSessionId(),
        },
        undefined,
      );
      ctx.abort();
    }
  });

  pi.on("turn_end", async (event, ctx) => {
    // Tools have finished and the next model request has not started yet.
    // Weekly balancing waits for idle/pre-run boundaries; urgency need not.
    if (event.outcome === "completed") {
      await refreshAll(ctx, false, false, false);
      await rotateAccounts(ctx, true, false);
    }
  });

  pi.on("agent_before_settle", async (event, ctx) => {
    if (event.outcome !== "error" || automaticRetryUsed || ctx.signal?.aborted)
      return;
    const entries = ctx.sessionManager.getEntries();
    const last = [...entries]
      .reverse()
      .find(
        (entry) =>
          entry.type === "message" && entry.message.role === "assistant",
      );
    if (
      last?.type !== "message" ||
      last.message.role !== "assistant" ||
      !/rate.?limit|usage.?limit|quota|429|额度|限额/iu.test(
        last.message.errorMessage ?? "",
      )
    )
      return;
    // Retry only a confirmed quota failure, at most once for this user run.
    // No retries for cancellation, network/auth errors or ordinary completion.
    await refreshAll(ctx, false, true, false);
    if (
      event.context.canContinue &&
      (await rotateAccounts(ctx, true, false, true))
    ) {
      automaticRetryUsed = true;
      return { continue: true };
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    await refreshAll(ctx, false);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    sessionActive = false;
    sessionController?.abort();
    sessionController = undefined;
    if (rotationInFlight) await rotationInFlight;
    await sessionAuth.clear(ctx);
    ctx.ui.setStatus(STATUS_KEY, undefined);
    if (ctx.mode === "rpc") ctx.ui.setStatus(GUI_STATUS_KEY, undefined);
  });
}

async function restoreModelForNewSession(
  pi: ExtensionAPI,
  event: SessionStartEvent,
  ctx: ExtensionContext,
): Promise<void> {
  if (event.reason !== "new" || !event.previousSessionFile) return;

  let entries;
  try {
    entries = SessionManager.open(event.previousSessionFile).getBranch();
  } catch (error) {
    ctx.ui.notify(`读取上一个会话模型失败：${errorMessage(error)}`, "warning");
    return;
  }

  const handoff = [...entries]
    .reverse()
    .find(
      (entry) =>
        entry.type === "custom" &&
        entry.customType === MODEL_HANDOFF_ENTRY_TYPE,
    );
  const data = handoff?.type === "custom" ? asRecord(handoff.data) : undefined;
  const provider = data?.provider;
  const modelId = data?.modelId;
  if (typeof provider !== "string" || typeof modelId !== "string") {
    ctx.ui.notify("上一个会话没有有效的模型交接记录。", "warning");
    return;
  }

  const model = ctx.modelRegistry.find(provider, modelId);
  if (!model) {
    ctx.ui.notify(
      `上一个会话使用的模型 ${provider}/${modelId} 当前不可用。`,
      "warning",
    );
    return;
  }
  if (ctx.model?.provider === provider && ctx.model.id === modelId) return;

  if (!(await pi.setModel(model))) {
    ctx.ui.notify(
      `无法恢复模型 ${provider}/${modelId}：未配置认证。`,
      "warning",
    );
  }
}

function restoreSessionAccount(
  ctx: ExtensionContext,
  state: CodexAccountState,
  provider: AccountProvider = "openai-codex",
  fallbackToDefault = true,
): string | undefined {
  const sessionId = ctx.sessionManager.getSessionId();
  const entries = ctx.sessionManager.getEntries();
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index];
    if (entry?.type !== "custom") continue;
    const data = asRecord(entry.data);
    if (data?.sessionId !== sessionId) continue;

    if (entry.customType === SELECTION_ENTRY_TYPE) {
      if ((data.provider ?? "openai-codex") !== provider) continue;
      const accountName = data.accountName;
      if (typeof accountName !== "string") {
        throw new Error("当前会话保存的 Codex 账户选择无效。");
      }
      requireExistingAccount(state, accountName);
      return accountName;
    }

    if (entry.customType === LEGACY_SELECTION_ENTRY_TYPE) {
      const providers = asRecord(data.providers);
      const accountName = providers?.[provider];
      if (typeof accountName === "string") {
        requireExistingAccount(state, accountName);
        return accountName;
      }
    }
  }
  return fallbackToDefault ? state.activeAccount : undefined;
}

function persistSessionSelection(
  pi: ExtensionAPI,
  ctx: ExtensionContext,
  accountName: string,
  provider: AccountProvider = "openai-codex",
): void {
  const data: SelectionEntryData = {
    version: 1,
    sessionId: ctx.sessionManager.getSessionId(),
    accountName,
    provider,
  };
  pi.appendEntry(SELECTION_ENTRY_TYPE, data);
}

function requireExistingAccount(
  state: CodexAccountState,
  accountName: string,
): void {
  if (!state.accounts.some((account) => account.name === accountName)) {
    throw new Error(`当前会话绑定的 Codex 账户 ${accountName} 不存在。`);
  }
}

function readAccountStateSafely(
  ctx: ExtensionContext,
  provider: AccountProvider,
): CodexAccountState | undefined {
  try {
    return createAccountStore(provider).readCodexAccountState();
  } catch (error) {
    logAccountAuthFailure(
      {
        provider,
        operation: "read_state",
        sessionId: ctx.sessionManager.getSessionId(),
      },
      error,
    );
    ctx.ui.setStatus(STATUS_KEY, "Codex 账户读取失败");
    ctx.ui.notify(errorMessage(error), "error");
    return undefined;
  }
}

function asRecord(value: unknown): Record<string, unknown> | undefined {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : undefined;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
