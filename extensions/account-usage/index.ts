import { normalizeContext } from "@earendil-works/pi-ai";
import {
  SessionManager,
  type ExtensionAPI,
  type ExtensionCommandContext,
  type ExtensionContext,
  type SessionStartEvent,
} from "@earendil-works/pi-coding-agent";
import { getSettingsListTheme } from "@earendil-works/pi-coding-agent";
import {
  Container,
  type SettingItem,
  SettingsList,
  Text,
} from "@earendil-works/pi-tui";
import {
  antigravityGUIStatus,
  formatAntigravityStatus,
  queryAntigravityUsage,
  validAntigravityUsageState,
  type AntigravityUsageState,
} from "./antigravity.js";
import { accountUsageCacheKey } from "./account-identity.js";
import { buildCachedReport, formatCachedReport } from "./cached-report.js";
import { buildUsageHealthReport, formatUsageHealth } from "./health.js";
import { CodexSessionAuth } from "./auth.js";
import { queryAccountUsage } from "./codex.js";
import { mapWithConcurrency } from "./concurrency.js";
import { logQuotaFailure } from "./diagnostics.js";
import { formatStatusSegment, formatUsageSummary } from "./format.js";
import { loginCodexAccount } from "./oauth.js";
import { readThroughSharedCache } from "./shared-cache.js";
import { validAccountUsages } from "./cache-validation.js";
import { nextAccount, REBALANCE_COOLDOWN_MS } from "./rotation.js";
import { createAccountStore } from "./store.js";
import { accountProvider, type AccountProvider } from "./types.js";
import type {
  AccountUsage,
  AutoWarmupRecord,
  CodexAccount,
  CodexAccountState,
  UsageSettings,
} from "./types.js";

const STATUS_KEY = "account-usage";
const GUI_STATUS_KEY = "account-usage-gui";
const SELECTION_ENTRY_TYPE = "codex-account-selection";
const LEGACY_SELECTION_ENTRY_TYPE = "pi-accounts-selection";
const MODEL_HANDOFF_ENTRY_TYPE = "model-handoff-on-new-session";
const ACTIVE_QUERY_INTERVAL_MS = 60 * 1_000;
const IDLE_QUERY_INTERVAL_MS = 3 * 60 * 1_000;
const COUNTDOWN_INTERVAL_MS = 60 * 1_000;
const FIVE_HOUR_WINDOW_SECONDS = 5 * 60 * 60;
const WEEKLY_WINDOW_SECONDS = 7 * 24 * 60 * 60;
const FRESH_WINDOW_TOLERANCE_MS = 5 * 60 * 1_000;
const AUTO_WARMUP_SUCCESS_COOLDOWN_MS = 10 * 60 * 1_000;
const LUNA_MODEL_ID = "gpt-5.6-luna";
const QUERY_CONCURRENCY = 2;

type SelectionEntryData = {
  version: 1;
  sessionId: string;
  accountName: string;
  provider: AccountProvider;
};

export default function codexAccountExtension(pi: ExtensionAPI) {
  let settings: UsageSettings = { version: 1, hiddenAccounts: [] };
  let usages = new Map<string, AccountUsage>();
  let usageIdentityKey: string | undefined;
  let activeRefreshes = 0;
  let antigravityUsage: AntigravityUsageState = { kind: "unconfigured" };
  let antigravityGeneration = 0;
  let lastAntigravityQueryAt = 0;
  let antigravityFlight:
    | { owner: AbortController; promise: Promise<void> }
    | undefined;
  let sessionActive = false;
  let sessionAccount: string | undefined;
  let authFailed = false;
  let sessionController: AbortController | undefined;
  let queryController: AbortController | undefined;
  let refreshTimer: ReturnType<typeof setTimeout> | undefined;
  let countdownTimer: ReturnType<typeof setInterval> | undefined;
  let autoWarmupRunning = false;
  let generation = 0;
  let refreshGeneration = 0;
  let providerId: AccountProvider = "openai-codex";
  let accountStore = createAccountStore(providerId);
  let sessionAuth = new CodexSessionAuth(providerId);
  let managesSelectedAuth = false;
  let rotationInFlight: Promise<boolean> | undefined;
  let lastRebalanceAt = 0;
  let lastFailedRotationAt = 0;
  let automaticRetryUsed = false;
  const accountContextGuard = (store: typeof accountStore) => {
    const owner = sessionController;
    return () => {
      if (
        !sessionActive ||
        store !== accountStore ||
        !owner ||
        owner !== sessionController ||
        owner.signal.aborted
      ) {
        throw new Error("账户管理会话或模型 provider 已变更，请重新执行命令。");
      }
    };
  };
  const updateVisibility = (hiddenAccounts: Iterable<string>) => {
    const updated: UsageSettings = {
      version: 1,
      hiddenAccounts: [...hiddenAccounts].sort(),
    };
    accountStore.writeSettings(updated);
    settings = updated;
  };
  const unhideAccount = (name: string) =>
    updateVisibility(
      settings.hiddenAccounts.filter((hidden) => hidden !== name),
    );
  const safeReadAccountState = (ctx: ExtensionContext) =>
    readAccountStateSafely(ctx, providerId);

  const usagesForState = (state: CodexAccountState): AccountUsage[] => {
    if (
      usageIdentityKey !==
      accountUsageCacheKey(visibleAccounts(state.accounts, settings))
    ) {
      usages.clear();
      usageIdentityKey = undefined;
    }
    return [...usages.values()];
  };

  const publishStatus = (ctx: ExtensionContext) => {
    const state = safeReadAccountState(ctx);
    if (!state) return;
    const visibleNames = new Set(
      visibleAccounts(state.accounts, settings).map((account) => account.name),
    );
    const visibleUsages = usagesForState(state).filter((usage) =>
      visibleNames.has(usage.accountName),
    );
    const segments = sortUsages(visibleUsages, sessionAccount).map((usage) =>
      formatStatusSegment(
        usage,
        sessionAccount,
        ctx.ui.theme,
        Date.now(),
        queryInterval(ctx),
      ),
    );
    const geminiIsActive =
      ctx.model?.provider === "antigravity" && /gemini/iu.test(ctx.model.id);
    const antigravitySegment = formatAntigravityStatus(
      antigravityUsage,
      geminiIsActive,
      ctx.ui.theme,
      Date.now(),
      queryInterval(ctx),
    );
    if (antigravitySegment) {
      if (geminiIsActive) segments.unshift(antigravitySegment);
      else segments.push(antigravitySegment);
    }
    if (ctx.mode !== "rpc") {
      ctx.ui.setStatus(
        STATUS_KEY,
        segments.length > 0 ? segments.join("  │  ") : undefined,
      );
    }

    // RPC 客户端可以用结构化数据绘制原生账户卡片；TUI 使用上面的
    // 彩色单行状态。每种界面只发布自己需要的一种状态，避免重复事件。
    if (ctx.mode === "rpc") {
      const hidden = new Set(settings.hiddenAccounts);
      ctx.ui.setStatus(
        GUI_STATUS_KEY,
        JSON.stringify({
          version: 2,
          provider: providerId,
          supportsAccountSwitch:
            ctx.model?.provider === providerId &&
            ctx.model.api !== "pi-virtual",
          managesSelectedAuth,
          activeAccount: managesSelectedAuth ? sessionAccount : undefined,
          defaultAccount: state.activeAccount,
          updatedAt: Date.now(),
          gemini: antigravityGUIStatus(antigravityUsage, geminiIsActive),
          accounts: state.accounts.map((account) => {
            const usage = usages.get(account.name);
            return {
              name: account.name,
              hidden: hidden.has(account.name),
              capturedAt: usage?.capturedAt,
              primary: usage?.primary,
              secondary: usage?.secondary,
              resetCredits: usage?.resetCredits,
              error: usage?.error,
            };
          }),
        }),
      );
    }
  };

  const queryInterval = (ctx: ExtensionContext) =>
    ctx.isIdle() ? IDLE_QUERY_INTERVAL_MS : ACTIVE_QUERY_INTERVAL_MS;

  const scheduleRefresh = (ctx: ExtensionContext) => {
    if (refreshTimer) clearTimeout(refreshTimer);
    refreshTimer = setTimeout(() => {
      refreshTimer = undefined;
      if (sessionActive) {
        void refreshAll(ctx, false).catch((error) => {
          if (sessionActive) {
            ctx.ui.notify(
              `刷新账户额度失败：${errorMessage(error)}`,
              "warning",
            );
          }
        });
      }
    }, queryInterval(ctx));
    refreshTimer.unref?.();
  };

  // 多账户查询需要限制并发、隔离单个账户失败，并防止旧会话结果覆盖新会话状态。
  const refreshCodexUsage = async (
    ctx: ExtensionContext,
    notify: boolean,
    force = false,
  ) => {
    const state = safeReadAccountState(ctx);
    if (!state) return;
    const queriedProvider = providerId;
    const visible = visibleAccounts(state.accounts, settings);
    const identityKey = accountUsageCacheKey(visible);
    if (usageIdentityKey !== identityKey) usages.clear();
    const currentGeneration = ++generation;
    queryController?.abort();
    const controller = new AbortController();
    queryController = controller;

    if (visible.length === 0) {
      usages.clear();
      if (notify) ctx.ui.notify(`没有可显示的 ${providerId} 账户。`, "info");
      return;
    }

    const results = await readThroughSharedCache({
      namespace: providerId === "openai" ? "openai-chatgpt" : "codex",
      key: identityKey,
      validate: (value) =>
        validAccountUsages(
          value,
          visible.map((account) => account.name),
        ),
      maxAgeMs: queryInterval(ctx),
      force: notify || force,
      signal: controller.signal,
      query: () =>
        mapWithConcurrency(
          visible,
          QUERY_CONCURRENCY,
          (account) => queryAccountUsage(account, controller.signal),
          controller.signal,
        ),
    });
    if (
      !sessionActive ||
      controller.signal.aborted ||
      currentGeneration !== generation
    ) {
      return;
    }

    // Another Pi process can replace a same-name login while this query is running.
    // Do not publish or warm up telemetry belonging to that previous identity.
    const latest = safeReadAccountState(ctx);
    if (
      !latest ||
      accountUsageCacheKey(visibleAccounts(latest.accounts, settings)) !==
        identityKey
    ) {
      usages.clear();
      usageIdentityKey = undefined;
      throw new Error("账户身份已变更，请重新刷新额度。");
    }
    usageIdentityKey = identityKey;
    usages = new Map(results.map((usage) => [usage.accountName, usage]));
    await runAutoWarmupCheck(ctx, visible, notify);
    if (
      !sessionActive ||
      queriedProvider !== providerId ||
      currentGeneration !== generation
    )
      return;
    if (notify) {
      ctx.ui.notify(
        formatUsageSummary(
          sortUsages(results, sessionAccount),
          sessionAccount,
          Date.now(),
          queryInterval(ctx),
        ),
        "info",
      );
    }
  };

  const queryAntigravityQuota = async (
    ctx: ExtensionContext,
    force: boolean,
  ) => {
    const now = Date.now();
    const interval = queryInterval(ctx);
    if (!force && now - lastAntigravityQueryAt < interval) return;

    const signal = sessionController?.signal;
    if (!signal) return;
    const currentGeneration = ++antigravityGeneration;
    const next = await readThroughSharedCache({
      namespace: "antigravity",
      key: "default",
      validate: validAntigravityUsageState,
      maxAgeMs: interval,
      force,
      signal,
      query: () => queryAntigravityUsage(ctx, signal),
    });
    if (
      !sessionActive ||
      signal.aborted ||
      currentGeneration !== antigravityGeneration
    ) {
      return;
    }
    antigravityUsage = next;
    lastAntigravityQueryAt = Date.now();
  };

  const refreshAntigravityUsage = (
    ctx: ExtensionContext,
    force: boolean,
  ): Promise<void> => {
    const owner = sessionController;
    if (!owner) return Promise.resolve();
    // A newer Codex refresh must await the ongoing Gemini query rather than
    // publishing a stale snapshot merely because its refresh interval has started.
    if (!force && antigravityFlight?.owner === owner) {
      return antigravityFlight.promise;
    }
    const flight = { owner, promise: Promise.resolve() };
    flight.promise = queryAntigravityQuota(ctx, force).finally(() => {
      if (antigravityFlight === flight) antigravityFlight = undefined;
    });
    antigravityFlight = flight;
    return flight.promise;
  };

  // 两类额度并行刷新，完成后只发布一次完整快照。
  const refreshAll = async (
    ctx: ExtensionContext,
    notify: boolean,
    forceCodex = false,
    rotateIdle = true,
  ) => {
    const startedAt = Date.now();
    activeRefreshes++;
    const currentRefresh = ++refreshGeneration;
    const owner = sessionController;
    const store = accountStore;
    const isCurrent = () =>
      sessionActive &&
      currentRefresh === refreshGeneration &&
      owner === sessionController &&
      !owner?.signal.aborted &&
      store === accountStore;
    try {
      // Drain both providers before publishing or scheduling: one cache/transport
      // failure must not hide the other provider's successfully refreshed quota.
      const results = await Promise.allSettled([
        refreshCodexUsage(ctx, notify, forceCodex),
        refreshAntigravityUsage(ctx, notify),
      ]);
      if (!isCurrent()) return;
      if (rotateIdle && results[0]?.status === "fulfilled") {
        await rotateAccounts(ctx);
      }
      if (!isCurrent()) return;
      publishStatus(ctx);
      const failures = results.flatMap((result) =>
        result.status === "rejected" && !isAbortError(result.reason)
          ? [result.reason]
          : [],
      );
      if (failures.length > 0) {
        throw new AggregateError(
          failures,
          "部分账户额度刷新失败，请稍后重试。",
        );
      }
    } catch (error) {
      // A newer refresh or session shutdown deliberately aborts the previous one.
      // Treat that as normal control flow instead of leaking an unhandled rejection.
      if (!isAbortError(error)) {
        logQuotaFailure(
          {
            provider: "shared",
            operation: "refresh_or_shared_cache",
            elapsedMs: Date.now() - startedAt,
          },
          error,
        );
        throw error;
      }
    } finally {
      activeRefreshes--;
      if (isCurrent()) scheduleRefresh(ctx);
    }
  };

  /**
   * 每次刷新分别领取刚刷新的 5h / 7d 窗口；同一账户两个窗口同时刷新只发送一次。
   * 同类窗口成功发送后冷却 10 分钟；5h 与 7d 独立判断，周限额不受 5h 冷却影响。
   */
  const runAutoWarmupCheck = async (
    ctx: ExtensionContext,
    accounts: readonly CodexAccount[],
    manualRefresh: boolean,
  ) => {
    if (autoWarmupRunning) return;
    const warmupProvider = providerId;
    const warmupStore = accountStore;
    autoWarmupRunning = true;
    try {
      const candidates = accounts.flatMap((account) => {
        const usage = usages.get(account.name);
        if (!usage) return [];
        const windows = (
          [
            ["5h", usage.primary, FIVE_HOUR_WINDOW_SECONDS],
            ["7d", usage.secondary, WEEKLY_WINDOW_SECONDS],
          ] as const
        ).flatMap(([kind, window, seconds]) => {
          const windowResetAt = freshWindowResetAt(usage, window, seconds);
          return windowResetAt === undefined ? [] : [{ kind, windowResetAt }];
        });
        return windows.length > 0 ? [{ account, windows }] : [];
      });
      if (candidates.length === 0) return;

      const signal = sessionController?.signal;
      if (!signal) return;
      const results = (
        await mapWithConcurrency(
          candidates,
          QUERY_CONCURRENCY,
          async ({ account, windows }) => {
            const claimed = [] as Array<(typeof windows)[number]>;
            for (const window of windows) {
              signal.throwIfAborted();
              if (
                await warmupStore.claimAutoWarmupWindow(
                  account.name,
                  window.windowResetAt,
                  Date.now(),
                  AUTO_WARMUP_SUCCESS_COOLDOWN_MS,
                  manualRefresh,
                  window.kind,
                )
              )
                claimed.push(window);
            }
            if (claimed.length === 0) return undefined;
            try {
              await warmupCodexAccount(ctx, account, signal);
              return {
                accountName: account.name,
                kinds: claimed.map((window) => window.kind),
                error: undefined,
              };
            } catch (error) {
              return {
                accountName: account.name,
                kinds: claimed.map((window) => window.kind),
                error: safeProviderErrorMessage(error),
              };
            }
          },
          signal,
        )
      ).filter((result) => result !== undefined);
      if (
        !sessionActive ||
        signal.aborted ||
        results.length === 0 ||
        warmupProvider !== providerId
      )
        return;

      const records: AutoWarmupRecord[] = results.flatMap((result) =>
        result.kinds.map((windowKind) => ({
          timestamp: Date.now(),
          accountName: result.accountName,
          windowKind,
          status:
            result.error === undefined
              ? ("success" as const)
              : ("failed" as const),
          error: result.error,
        })),
      );
      try {
        await warmupStore.appendAutoWarmupRecords(records);
      } catch (error) {
        ctx.ui.notify(
          `保存自动启动记录失败：${errorMessage(error)}`,
          "warning",
        );
      }

      const succeeded = results
        .filter((result) => result.error === undefined)
        .map((result) => `${result.accountName}（${result.kinds.join("、")}）`);
      const failed = results.filter((result) => result.error !== undefined);
      if (succeeded.length > 0) {
        ctx.ui.notify(
          `已用 Luna(low) 向 ${succeeded.join("、")} 发送“你好”，启动额度倒计时。`,
          "info",
        );
      }
      for (const result of failed) {
        ctx.ui.notify(
          `账户 ${result.accountName} 自动启动倒计时失败：${result.error}`,
          "warning",
        );
      }
    } catch (error) {
      if (sessionActive && !isAbortError(error)) {
        ctx.ui.notify(
          `自动检查 ${providerId} 账户失败：${errorMessage(error)}`,
          "warning",
        );
      }
    } finally {
      autoWarmupRunning = false;
    }
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
      throw error;
    }
  };

  // Automatic changes are session-local. Manual /accounts switch still changes
  // the future default. Never abort tools or inject/replay a user's prompt.
  const rotateAccounts = async (
    ctx: ExtensionContext,
    boundary = false,
    allowRebalance = true,
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
    const decision = nextAccount({
      activeAccount: previous,
      usages: usagesForState(state).filter((usage) =>
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
    await store.setActiveAccount(accountName);
    assertCurrent();
    managesSelectedAuth = true;
    persistSessionSelection(pi, ctx, accountName, providerId);
    sessionAccount = accountName;
    publishStatus(ctx);
    await refreshAll(ctx, false);
    ctx.ui.notify(
      `已切换到 ${accountName}。当前会话和之后的新会话将使用该账户；其他旧会话保持不变。`,
      "info",
    );
  };

  const loginAccount = async (ctx: ExtensionCommandContext) => {
    if (!ctx.isIdle()) throw new Error("请先停止当前任务再登录账户。");
    const store = accountStore;
    const assertCurrent = accountContextGuard(store);
    const loginProvider = providerId;
    const ownerSignal = sessionController?.signal;
    const input = await ctx.ui.input(
      `新 ${providerId === "openai" ? "OpenAI ChatGPT" : "Codex legacy"} 账户名称`,
      "仅允许字母、数字、点、下划线和连字符",
    );
    if (input === undefined) return;
    assertCurrent();
    const accountName = input.trim();
    if (!/^[A-Za-z0-9._-]{1,64}$/u.test(accountName)) {
      ctx.ui.notify("账户名称格式无效。", "error");
      return;
    }

    const existing = store
      .readCodexAccountState()
      .accounts.some((account) => account.name === accountName);
    if (
      existing &&
      !(await ctx.ui.confirm(
        "覆盖账户",
        `账户 ${accountName} 已存在，是否重新登录并覆盖？`,
      ))
    ) {
      return;
    }

    assertCurrent();
    const controller = new AbortController();
    const abortLogin = () => controller.abort();
    ownerSignal?.addEventListener("abort", abortLogin, {
      once: true,
    });
    try {
      const credential = await loginCodexAccount(
        ctx,
        controller.signal,
        loginProvider,
      );
      assertCurrent();
      await store.saveAccount(accountName, credential);
      assertCurrent();
      await activateForSession(ctx, accountName);
      assertCurrent();
      await store.setActiveAccount(accountName);
      assertCurrent();
      managesSelectedAuth = true;
      persistSessionSelection(pi, ctx, accountName, providerId);
      sessionAccount = accountName;
      unhideAccount(accountName);
      await refreshAll(ctx, false);
      ctx.ui.notify(
        `账户 ${accountName} 已登录，并设为当前及后续新会话的默认账户。`,
        "info",
      );
    } finally {
      ownerSignal?.removeEventListener("abort", abortLogin);
      controller.abort();
    }
  };

  const deleteAccount = async (ctx: ExtensionCommandContext) => {
    const store = accountStore;
    const assertCurrent = accountContextGuard(store);
    const state = store.readCodexAccountState();
    const removable = state.accounts.filter(
      (account) =>
        account.name !== state.activeAccount && account.name !== sessionAccount,
    );
    if (removable.length === 0) {
      ctx.ui.notify("没有可删除的账户；请先切换当前默认账户。", "warning");
      return;
    }
    const selected = await ctx.ui.select(
      `选择要删除的 ${providerId} 账户`,
      removable.map((account) => account.name),
    );
    if (!selected) return;
    assertCurrent();
    if (
      !(await ctx.ui.confirm(
        "删除账户",
        `确定删除账户 ${selected}？仍在使用它的旧会话之后将无法继续请求。`,
      ))
    ) {
      return;
    }
    assertCurrent();
    await store.removeAccount(selected);
    assertCurrent();
    usages.delete(selected);
    unhideAccount(selected);
    publishStatus(ctx);
    ctx.ui.notify(`账户 ${selected} 已删除。`, "info");
  };

  const showAutoWarmupRecords = async (ctx: ExtensionContext) => {
    try {
      const records = await accountStore.readAutoWarmupRecords();
      ctx.ui.notify(formatAutoWarmupRecords(records), "info");
    } catch (error) {
      ctx.ui.notify(`读取自动启动记录失败：${errorMessage(error)}`, "error");
    }
  };

  const showUsageHealth = (ctx: ExtensionContext, json = false) => {
    const state = safeReadAccountState(ctx);
    if (!state) return;
    const options = {
      provider: providerId,
      managed: managesSelectedAuth,
      authFailed,
      accountNames: state.accounts.map((account) => account.name),
      hiddenNames: settings.hiddenAccounts,
      usages: usagesForState(state),
      maxAgeMs: queryInterval(ctx),
      gemini: antigravityUsage.kind,
      refreshing: activeRefreshes > 0,
    };
    ctx.ui.notify(
      json
        ? JSON.stringify(buildUsageHealthReport(options), null, 2)
        : formatUsageHealth(options),
      "info",
    );
  };

  const openAccountsMenu = async (ctx: ExtensionCommandContext) => {
    const assertCurrent = accountContextGuard(accountStore);
    while (true) {
      assertCurrent();
      const state = safeReadAccountState(ctx);
      if (!state) return;
      const accountLines = state.accounts.map((account) => {
        const markers = [
          account.name === sessionAccount ? "当前会话" : undefined,
          account.name === state.activeAccount ? "新会话默认" : undefined,
        ].filter(Boolean);
        return `${account.name}${markers.length > 0 ? `（${markers.join("、")}）` : ""}`;
      });
      const action = await ctx.ui.select(
        [
          `${providerId === "openai" ? "OpenAI ChatGPT" : "Codex legacy"} 多账户管理`,
          "",
          ...(accountLines.length > 0 ? accountLines : ["尚未登录账户"]),
        ].join("\n"),
        [
          "切换账户",
          "刷新额度",
          "登录新账户",
          "删除账户",
          "额度显示设置",
          "自动启动记录",
          "健康检查",
          "关闭",
        ],
      );
      if (!action || action === "关闭") return;
      assertCurrent();
      if (action === "切换账户") {
        if (state.accounts.length === 0) {
          ctx.ui.notify("请先登录一个账户。", "warning");
          continue;
        }
        const selected = await ctx.ui.select(
          `选择 ${providerId} 账户`,
          state.accounts.map((account) =>
            account.name === sessionAccount
              ? `✓ ${account.name}`
              : account.name,
          ),
        );
        if (selected) {
          assertCurrent();
          await switchAccount(ctx, selected.replace(/^✓\s+/u, ""));
          return;
        }
      }
      if (action === "刷新额度") await refreshAll(ctx, true);
      if (action === "登录新账户") await loginAccount(ctx);
      if (action === "删除账户") await deleteAccount(ctx);
      if (action === "额度显示设置") await openVisibilitySettings(ctx);
      if (action === "自动启动记录") await showAutoWarmupRecords(ctx);
      if (action === "健康检查") showUsageHealth(ctx);
    }
  };

  const openVisibilitySettings = async (ctx: ExtensionCommandContext) => {
    const store = accountStore;
    const assertCurrent = accountContextGuard(store);
    const state = safeReadAccountState(ctx);
    if (!state || state.accounts.length === 0) return;
    const hidden = new Set(settings.hiddenAccounts);

    // custom() 只属于 TUI；RPC/GUI 使用标准 select 协议，客户端会显示原生对话框。
    if (ctx.mode !== "tui") {
      const selected = await ctx.ui.select(
        "选择要显示或隐藏额度的账户",
        state.accounts.map(
          (account) =>
            `${hidden.has(account.name) ? "○" : "✓"} ${account.name}`,
        ),
      );
      if (!selected) return;
      assertCurrent();
      const accountName = selected.replace(/^[○✓]\s+/u, "");
      if (hidden.has(accountName)) hidden.delete(accountName);
      else hidden.add(accountName);
      updateVisibility(hidden);
      if (hidden.has(accountName)) usages.delete(accountName);
      await refreshAll(ctx, false);
      return;
    }

    await ctx.ui.custom<void>((tui, theme, _keybindings, done) => {
      const items: SettingItem[] = state.accounts.map((account) => ({
        id: account.name,
        label: account.name,
        ...(account.name === sessionAccount
          ? { description: "当前会话正在使用" }
          : {}),
        currentValue: hidden.has(account.name) ? "隐藏" : "显示",
        values: ["显示", "隐藏"],
      }));
      const container = new Container();
      container.addChild(
        new Text(
          theme.fg("accent", theme.bold(`${providerId} 账户额度显示设置`)),
          1,
          1,
        ),
      );
      const list = new SettingsList(
        items,
        Math.min(items.length + 2, 12),
        getSettingsListTheme(),
        (id, value) => {
          if (value === "隐藏") hidden.add(id);
          else hidden.delete(id);
          try {
            assertCurrent();
            updateVisibility(hidden);
            usages.delete(id);
            publishStatus(ctx);
          } catch (error) {
            ctx.ui.notify(errorMessage(error), "error");
          }
          tui.requestRender();
        },
        () => done(undefined),
      );
      container.addChild(list);
      container.addChild(
        new Text(theme.fg("dim", "↑↓ 选择 · ←→ 切换 · Esc 关闭"), 1, 0),
      );
      return {
        render: (width) => container.render(width),
        invalidate: () => container.invalidate(),
        handleInput: (data) => {
          list.handleInput?.(data);
          tui.requestRender();
        },
      };
    });
    await refreshAll(ctx, false);
  };

  pi.registerCommand("accounts", {
    description:
      "管理、登录和切换 OpenAI ChatGPT / Codex 账户（按当前模型隔离）",
    handler: async (args, ctx) => {
      const match = args.trim().match(/^switch\s+([A-Za-z0-9._-]{1,64})$/u);
      if (match?.[1]) {
        const state = safeReadAccountState(ctx);
        if (!state) return;
        requireExistingAccount(state, match[1]);
        await switchAccount(ctx, match[1]);
        return;
      }
      if (args.trim()) {
        ctx.ui.notify("用法：/accounts [switch <账户名>]", "warning");
        return;
      }
      await openAccountsMenu(ctx);
    },
  });

  pi.registerCommand("usage", {
    description: "查看当前 OpenAI ChatGPT / Codex 账户的剩余额度和重置时间",
    handler: async (args, ctx) => {
      const action = args.trim();
      if (action === "doctor" || action === "doctor json") {
        showUsageHealth(ctx, action === "doctor json");
        return;
      }
      if (action === "refresh") {
        await refreshAll(ctx, true);
        return;
      }
      if (action === "settings") {
        await openVisibilitySettings(ctx);
        return;
      }
      if (action === "history") {
        await showAutoWarmupRecords(ctx);
        return;
      }
      if (action === "cached" || action === "cached json") {
        const state = safeReadAccountState(ctx);
        if (!state) return;
        const visibleNames = new Set(
          visibleAccounts(state.accounts, settings).map(
            (account) => account.name,
          ),
        );
        const snapshot = sortUsages(
          usagesForState(state).filter((usage) =>
            visibleNames.has(usage.accountName),
          ),
          sessionAccount,
        );
        const maxAgeMs = queryInterval(ctx);
        const report = buildCachedReport({
          provider: providerId,
          visibleNames: [...visibleNames],
          usages: snapshot,
          activeAccount: sessionAccount,
          now: Date.now(),
          maxAgeMs,
        });
        ctx.ui.notify(
          action === "cached json"
            ? JSON.stringify(report, null, 2)
            : formatCachedReport(report, snapshot, sessionAccount, maxAgeMs),
          "info",
        );
        return;
      }
      if (action === "show") {
        await refreshAll(ctx, false);
        ctx.ui.notify(
          formatUsageSummary(
            sortUsages([...usages.values()], sessionAccount),
            sessionAccount,
            Date.now(),
            queryInterval(ctx),
          ),
          "info",
        );
        return;
      }
      if (action) {
        ctx.ui.notify(
          "用法：/usage [refresh|settings|history|show|cached [json]|doctor [json]]",
          "warning",
        );
        return;
      }
      await refreshAll(ctx, false);
      ctx.ui.notify(
        formatUsageSummary(
          sortUsages([...usages.values()], sessionAccount),
          sessionAccount,
          Date.now(),
          queryInterval(ctx),
        ),
        "info",
      );
    },
  });

  pi.on("session_before_switch", (event, ctx) => {
    if (event.reason !== "new" || !ctx.model) return;
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
    usageIdentityKey = undefined;
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
              "尚未配置 Codex 账户，请运行 /accounts 登录。",
              "warning",
            );
        }
      } catch (error) {
        sessionAccount = undefined;
        authFailed = true;
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

    // The native RPC client renders reset countdowns locally. Re-publishing the same
    // snapshot every minute only creates duplicate extension_ui_request events there.
    if (ctx.mode !== "rpc") {
      countdownTimer = setInterval(
        () => publishStatus(ctx),
        COUNTDOWN_INTERVAL_MS,
      );
      countdownTimer.unref?.();
    }
    await refreshAll(ctx, false);
  });

  pi.on("model_select", async (_event, ctx) => {
    if (accountProvider(ctx.model?.provider) !== providerId) {
      generation += 1;
      queryController?.abort();
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

  pi.on("agent_start", (_event, ctx) => {
    // A running agent uses the one-minute cadence immediately, even if this timer was
    // previously scheduled while the session was idle.
    scheduleRefresh(ctx);
  });

  pi.on("turn_start", (_event, ctx) => {
    if (
      ctx.model?.provider === providerId &&
      ctx.model.api !== "pi-virtual" &&
      authFailed
    )
      ctx.abort();
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
    if (event.context.canContinue && (await rotateAccounts(ctx, true, false))) {
      automaticRetryUsed = true;
      return { continue: true };
    }
  });

  pi.on("agent_settled", async (_event, ctx) => {
    await refreshAll(ctx, false);
  });

  pi.on("session_shutdown", async (_event, ctx) => {
    sessionActive = false;
    generation += 1;
    antigravityGeneration += 1;
    antigravityUsage = { kind: "unconfigured" };
    lastAntigravityQueryAt = 0;
    sessionController?.abort();
    sessionController = undefined;
    if (rotationInFlight) await rotationInFlight;
    queryController?.abort();
    queryController = undefined;
    if (refreshTimer) clearTimeout(refreshTimer);
    refreshTimer = undefined;
    if (countdownTimer) clearInterval(countdownTimer);
    countdownTimer = undefined;
    await sessionAuth.clear(ctx);
    ctx.ui.setStatus(STATUS_KEY, undefined);
    if (ctx.mode === "rpc") ctx.ui.setStatus(GUI_STATUS_KEY, undefined);
  });
}

// /new 前把当前模型写入旧会话，新会话完成账户认证后再恢复；启动和 /resume 均不介入。
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

function freshWindowResetAt(
  usage: AccountUsage,
  window: AccountUsage["primary"],
  windowSeconds: number,
): number | undefined {
  if (
    usage.error !== undefined ||
    window === undefined ||
    window.remainingPercent !== 100 ||
    window.windowSeconds !== windowSeconds ||
    window.resetAt === undefined
  ) {
    return undefined;
  }

  const countdownMs = window.resetAt * 1_000 - usage.capturedAt;
  const isFreshWindow =
    countdownMs >= windowSeconds * 1_000 - FRESH_WINDOW_TOLERANCE_MS &&
    countdownMs <= windowSeconds * 1_000 + FRESH_WINDOW_TOLERANCE_MS;
  return isFreshWindow ? window.resetAt : undefined;
}

async function warmupCodexAccount(
  ctx: ExtensionContext,
  account: CodexAccount,
  signal: AbortSignal,
): Promise<void> {
  signal.throwIfAborted();
  const providerId = account.provider ?? "openai-codex";
  const model = ctx.modelRegistry.find(providerId, LUNA_MODEL_ID);
  if (!model) throw new Error(`模型 ${providerId}/${LUNA_MODEL_ID} 不可用。`);
  const provider = ctx.modelRegistry.getProvider(providerId);
  if (!provider) throw new Error(`${providerId} provider 不可用。`);

  const response = await provider
    .streamSimple(
      model,
      normalizeContext({
        messages: [{ role: "user", content: "你好", timestamp: Date.now() }],
      }),
      {
        apiKey: account.credential.access,
        reasoning: "low",
        toolChoice: "none",
        maxTokens: 64,
        timeoutMs: 60_000,
        transport: "sse",
        signal,
      },
    )
    .result();
  if (response.stopReason === "error" || response.stopReason === "aborted") {
    throw new Error(
      response.errorMessage ?? `请求以 ${response.stopReason} 结束。`,
    );
  }
}

function visibleAccounts(
  accounts: readonly CodexAccount[],
  settings: UsageSettings,
): CodexAccount[] {
  const hidden = new Set(settings.hiddenAccounts);
  return accounts.filter((account) => !hidden.has(account.name));
}

function sortUsages(
  usages: readonly AccountUsage[],
  activeAccount: string | undefined,
): AccountUsage[] {
  return [...usages].sort((left, right) => {
    const leftIsActive = left.accountName === activeAccount;
    const rightIsActive = right.accountName === activeAccount;
    if (leftIsActive !== rightIsActive) return leftIsActive ? -1 : 1;
    return left.accountName.localeCompare(right.accountName);
  });
}

function readAccountStateSafely(
  ctx: ExtensionContext,
  provider: AccountProvider,
): CodexAccountState | undefined {
  try {
    return createAccountStore(provider).readCodexAccountState();
  } catch (error) {
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

function formatAutoWarmupRecords(records: readonly AutoWarmupRecord[]): string {
  if (records.length === 0) return "暂无自动启动记录。";
  const latest = records.slice(-20).reverse();
  return [
    `最近 ${latest.length} 条自动启动记录：`,
    ...latest.map((record) => {
      const time = new Date(record.timestamp).toLocaleString("zh-CN", {
        hour12: false,
      });
      return record.status === "success"
        ? `${time}  ${record.accountName}（${record.windowKind ?? "5h"}）  已发送“你好”`
        : `${time}  ${record.accountName}（${record.windowKind ?? "5h"}）  发送失败：${record.error}`;
    }),
  ].join("\n");
}

function safeProviderErrorMessage(error: unknown): string {
  return errorMessage(error)
    .replace(/Bearer\s+\S+/giu, "Bearer [REDACTED]")
    .slice(0, 200);
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
