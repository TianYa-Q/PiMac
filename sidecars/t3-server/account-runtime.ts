import { realpathSync, existsSync, readFileSync, statSync } from "node:fs";
import { findPackageJSON } from "node:module";
import { join, delimiter, dirname, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { randomUUID, createHash } from "node:crypto";
import type {
  OAuthCredential,
  ProviderAuthInteraction,
  AccountSDK,
  HostQuotaSnapshot,
} from "../../extensions/account-usage/host-types.js";
import { getAgentDirectory } from "../../extensions/account-usage/agent-directory.js";
import { createAccountStore } from "../../extensions/account-usage/store.js";
import {
  resolveAccountId,
  accountUsageCacheKey,
} from "../../extensions/account-usage/account-identity.js";
import { withDeadline } from "../../extensions/account-usage/deadline.js";
import { writeHostSnapshot } from "../../extensions/account-usage/host-snapshot.js";
import { appendPrivateDiagnostic } from "../../extensions/account-usage/private-log.js";
import {
  readPrivateRegularFile,
  writePrivateJson,
} from "../../extensions/account-usage/private-json.js";
import { mapWithConcurrency } from "../../extensions/account-usage/concurrency.js";
import type {
  AccountProvider,
  AccountUsage,
  CodexAccount,
  UsageWindow,
} from "../../extensions/account-usage/types.js";
import { createPiAccountManagement } from "../../Sources/PiMacApp/Resources/t3-bridge/pi-account-management.mjs";

type Sample = HostQuotaSnapshot & {
  activation?: { accounts: CodexAccount[]; usages: AccountUsage[] };
};
type Dialog = {
  id: string;
  method: "select" | "input" | "confirm";
  title: string;
  options?: string[];
  message?: string;
  placeholder?: string;
};
type Event = Record<string, unknown> & {
  id: string;
  method: string;
  serial: number;
};
type Control =
  | { operation: "open"; provider: AccountProvider }
  | { operation: "poll" | "cancel"; flowID: string }
  | {
      operation: "respond";
      flowID: string;
      id: string;
      value?: string;
      confirmed?: boolean;
      cancelled: boolean;
    };

function parseControl(value: unknown): Control {
  if (!value || typeof value !== "object" || Array.isArray(value))
    throw new Error("Invalid control");
  const input = value as Record<string, unknown>;
  if (input.operation === "open") {
    if (input.provider !== "openai" && input.provider !== "openai-codex")
      throw new Error("Unsupported provider");
    return { operation: "open", provider: input.provider };
  }
  if (
    input.operation !== "poll" &&
    input.operation !== "cancel" &&
    input.operation !== "respond"
  )
    throw new Error("Invalid operation");
  if (typeof input.flowID !== "string" || input.flowID.length > 128)
    throw new Error("Invalid flow ID");
  if (input.operation !== "respond")
    return { operation: input.operation, flowID: input.flowID };
  if (
    typeof input.id !== "string" ||
    input.id.length > 128 ||
    (input.value != null &&
      (typeof input.value !== "string" || input.value.length > 32768)) ||
    (input.confirmed != null && typeof input.confirmed !== "boolean") ||
    (input.cancelled != null && typeof input.cancelled !== "boolean")
  )
    throw new Error("Invalid response");
  return {
    operation: "respond",
    flowID: input.flowID,
    id: input.id,
    ...(typeof input.value === "string" ? { value: input.value } : {}),
    ...(typeof input.confirmed === "boolean"
      ? { confirmed: input.confirmed }
      : {}),
    cancelled: input.cancelled === true,
  };
}
type Flow = {
  id: string;
  controller: AbortController;
  requests: Map<
    string,
    { dialog: Dialog; reply(value: string | boolean | undefined): void }
  >;
  events: Event[];
  serial: number;
  busy: boolean;
};

/** 加载当前安装的 Pi 官方 provider 实现，不内置另一套 OAuth 或锁定宿主模型目录。 */
export async function loadAccountSDK(binaryPath: string): Promise<AccountSDK> {
  const binary = binaryPath.includes("/")
    ? binaryPath
    : (process.env.PATH ?? "")
        .split(delimiter)
        .map((directory) => join(directory, binaryPath))
        .find((file) => existsSync(file));
  if (!binary) throw new Error("Pi executable not found");
  let entry = realpathSync(binary);
  // npm 通常使用符号链接，pnpm 则使用带目标元数据的 shell shim；只解析标准
  // 目标标记，不执行 shell、不搜索任意其他版本，也不回退到应用自己的旧 SDK。
  if (statSync(entry).size <= 64 * 1024) {
    const source = readFileSync(entry, "utf8");
    const target =
      source.match(/^# cmd-shim-target=(.+)$/m)?.[1] ??
      source.match(
        /"\$basedir\/([^"\n]*@earendil-works\/pi-coding-agent\/dist\/[^"\n]*cli\.js)"/,
      )?.[1];
    if (target) entry = realpathSync(resolve(dirname(entry), target));
  }
  const manifestPath = findPackageJSON(
    "@earendil-works/pi-ai",
    pathToFileURL(entry),
  );
  if (!manifestPath) throw new Error("Installed Pi SDK not found");
  const manifest = JSON.parse(readFileSync(manifestPath, "utf8"));
  const main = manifest.exports?.["."]?.import;
  const providers = manifest.exports?.["./providers/*"]?.import;
  if (
    manifest.name !== "@earendil-works/pi-ai" ||
    typeof main !== "string" ||
    typeof providers !== "string"
  )
    throw new Error("Unsupported Pi SDK exports");
  const aiURL = pathToFileURL(resolve(dirname(manifestPath), main)).href;
  const providersURL = pathToFileURL(
    resolve(dirname(manifestPath), providers.replace("*", "all")),
  ).href;
  const [ai, builtins] = await Promise.all([
    import(aiURL),
    import(providersURL),
  ]);
  return {
    providers: builtins.builtinProviders(),
    normalizeContext: ai.normalizeContext,
  };
}

export function activationReason(
  window: UsageWindow | undefined,
  capturedAt: number,
  now: number,
  seconds: number,
): string {
  if (now - capturedAt > 180_000 || capturedAt > now + 5_000) return "stale";
  if (
    !window ||
    window.resetAt === undefined ||
    window.windowSeconds !== seconds
  )
    return "unknown-window";
  if (window.remainingPercent !== 100) return "not-full";
  const remaining = window.resetAt * 1000 - capturedAt;
  // 已过期且已满额的窗口也要补查；但仍在倒计时的 100% 可能只是用量取整，不能重复发送。
  if (remaining <= 0 || Math.abs(remaining - seconds * 1000) <= 300_000)
    return "eligible";
  return "countdown-active";
}

export function createAccountRuntime({
  binaryPath = "pi",
  directory = getAgentDirectory(),
  now = Date.now,
  sdk = () => loadAccountSDK(binaryPath),
  fetchImpl = fetch,
  intervalMs = 60_000,
} = {}) {
  const owner = new AbortController();
  const stores = new Map<
    AccountProvider,
    ReturnType<typeof createAccountStore>
  >();
  const flights = new Map<string, Promise<Sample>>();
  const flows = new Map<string, Flow>();
  const flowTasks = new Set<Promise<void>>();
  const sampledIdentities = new Map<string, string>();
  let timer: ReturnType<typeof setInterval> | undefined;
  let tickFlight: Promise<void> | undefined;
  const storeFor = (provider: AccountProvider) => {
    let store = stores.get(provider);
    if (!store) {
      store = createAccountStore(provider, directory);
      stores.set(provider, store);
    }
    return store;
  };
  const log = (record: Record<string, unknown>) => {
    try {
      appendPrivateDiagnostic(join(directory, "pimac-account-monitor.jsonl"), {
        timestamp: new Date(now()).toISOString(),
        ...record,
      });
    } catch {
      /* 日志故障不得阻止额度查询；不记录 token、URL、响应体或原始错误文本。 */
    }
  };
  const deviceID = () => {
    const file = join(directory, "pimac-account-device.json");
    let value: unknown;
    try {
      value = JSON.parse(readPrivateRegularFile(file));
    } catch (error) {
      if (
        !(error instanceof Error && "code" in error && error.code === "ENOENT")
      )
        throw error;
      const id = randomUUID();
      writePrivateJson(file, { deviceID: id });
      return id;
    }
    if (
      !value ||
      typeof value !== "object" ||
      !("deviceID" in value) ||
      typeof value.deviceID !== "string" ||
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/iu.test(
        value.deviceID,
      )
    ) {
      throw new Error("Invalid installation device ID");
    }
    return value.deviceID;
  };
  const providerFor = async (id: AccountProvider) => {
    const runtime = await sdk();
    const provider = runtime.providers.find((provider) => provider.id === id);
    if (!provider?.auth.oauth)
      throw new Error("Official OAuth provider unavailable");
    return { runtime, provider, oauth: provider.auth.oauth };
  };
  const transport = createPiAccountManagement({
    agentDirectory: directory,
    now,
    fetchImpl,
    resolveCredential: async (
      provider: AccountProvider,
      name: string,
      credential: OAuthCredential,
      signal: AbortSignal,
      force: boolean,
    ) => {
      const store = storeFor(provider);
      // 原生 auth.json 仍由 Pi 管理。托管账户必须使用并刷新自己的 grant，
      // 不能因查询层合并了较新的原生 token 而永远留下过期的托管凭据。
      const managed = store
        .readCodexAccountState()
        .accounts.find((account) => account.name === name);
      if (!managed) return credential;
      if (
        managed.credential.expires > now() + 300_000 &&
        (!force || managed.credential.access !== credential.access)
      )
        return managed.credential;
      return store.refreshStoredCredential(name, async (latest) => {
        signal.throwIfAborted();
        if (
          latest.expires > now() + 300_000 &&
          (!force || latest.access !== credential.access)
        )
          return latest;
        const { oauth } = await providerFor(provider);
        const refreshed = await oauth.refresh(latest, signal);
        signal.throwIfAborted();
        return { ...latest, ...refreshed };
      });
    },
  }) as {
    accountStatus(options: {
      provider: string;
      force: boolean;
    }): Promise<HostQuotaSnapshot>;
    close(): void;
  };

  async function activate(
    providerID: AccountProvider,
    account: CodexAccount,
    usage: AccountUsage,
  ): Promise<void> {
    const store = storeFor(providerID);
    const identityKey = createHash("sha256")
      .update(
        JSON.stringify([
          providerID,
          resolveAccountId(account.credential) ?? account.credential.access,
        ]),
      )
      .digest("hex");
    const windows = (
      [
        ["5h", usage.primary, 18_000],
        ["7d", usage.secondary, 604_800],
      ] as const
    ).filter(([kind, window, seconds]) => {
      const reason = usage.error
        ? "query-failed"
        : activationReason(window, usage.capturedAt, now(), seconds);
      log({
        operation: "activation-check",
        provider: providerID,
        accountName: account.name,
        window: kind,
        remainingPercent: window?.remainingPercent,
        resetAt: window?.resetAt,
        capturedAt: usage.capturedAt,
        reason,
      });
      return reason === "eligible";
    });
    if (!windows.length) return;
    const kinds: Array<"5h" | "7d"> = [];
    for (const [kind, window] of windows) {
      owner.signal.throwIfAborted();
      if (
        await store.claimAutoWarmupWindow(
          account.name,
          window!.resetAt!,
          now(),
          600_000,
          false,
          kind,
          identityKey,
        )
      )
        kinds.push(kind);
      else
        log({
          operation: "activation-skip",
          provider: providerID,
          accountName: account.name,
          window: kind,
          reason: "claimed-or-cooldown",
        });
    }
    if (!kinds.length) return;
    let failed = false;
    let stage = "load-provider";
    try {
      const { runtime, provider } = await providerFor(providerID);
      owner.signal.throwIfAborted();
      stage = "identity-check";
      // 查询和发送之间重新核对身份及可见性，避免同名重新登录或隐藏操作使用旧凭据。
      const latest = store
        .readCodexAccountState()
        .accounts.find((candidate) => candidate.name === account.name);
      if (
        !latest ||
        store.readSettings().hiddenAccounts.includes(account.name) ||
        (resolveAccountId(latest.credential) ?? latest.credential.access) !==
          (resolveAccountId(account.credential) ?? account.credential.access)
      ) {
        throw new Error("Account changed");
      }
      stage = "select-model";
      const model = provider
        .getModels()
        .find((model) => model.id === "gpt-5.6-luna");
      if (!model) throw new Error("Activation model unavailable");
      stage = "model-request";
      const response = await withDeadline(
        (signal) =>
          provider
            .streamSimple(
              model,
              runtime.normalizeContext({
                messages: [{ role: "user", content: "你好", timestamp: now() }],
              }),
              {
                apiKey: latest.credential.access,
                reasoning: "low",
                toolChoice: "none",
                maxTokens: 64,
                timeoutMs: 60_000,
                transport: "sse",
                signal,
              },
            )
            .result(),
        owner.signal,
        60_000,
      );
      if (response.stopReason === "error" || response.stopReason === "aborted")
        throw new Error("Activation failed");
    } catch {
      failed = true;
    }
    await store.appendAutoWarmupRecords(
      kinds.map((windowKind) => ({
        timestamp: now(),
        accountName: account.name,
        windowKind,
        identityKey,
        status: failed ? "failed" : "success",
        error: failed
          ? "PiMac 激活请求失败；后台将重试，请检查授权、网络和模型可用性。"
          : undefined,
      })),
    );
    log({
      operation: "activation-result",
      provider: providerID,
      accountName: account.name,
      windows: kinds,
      status: failed ? "failed" : "success",
      ...(failed ? { failureStage: stage } : {}),
    });
  }

  async function sample(provider: string, force: boolean): Promise<Sample> {
    log({ operation: "sample-start", provider, force });
    if (provider !== "openai" && provider !== "openai-codex") {
      const result = await transport.accountStatus({ provider, force });
      log({
        operation: "sample-result",
        provider,
        capturedAt: result.updatedAt,
        cached: result.cached === true,
      });
      return result;
    }
    const store = storeFor(provider);
    const settings = store.readSettings();
    const before = store
      .readCodexAccountState()
      .accounts.filter(
        (account) => !settings.hiddenAccounts.includes(account.name),
      );
    const identity = accountUsageCacheKey(before);
    const result = await transport.accountStatus({
      provider,
      force: force || sampledIdentities.get(provider) !== identity,
    });
    owner.signal.throwIfAborted();
    const latestSettings = store.readSettings();
    const accounts = store
      .readCodexAccountState()
      .accounts.filter(
        (account) => !latestSettings.hiddenAccounts.includes(account.name),
      );
    if (accountUsageCacheKey(accounts) !== identity)
      throw new Error("Account identity changed during sampling");
    sampledIdentities.set(provider, identity);
    const usages: AccountUsage[] = accounts.map((account) => {
      const row = result.accounts.find((row) => row.name === account.name);
      return {
        accountName: account.name,
        capturedAt: row?.capturedAt ?? now(),
        primary: row?.primary,
        secondary: row?.secondary,
        resetCredits: row?.resetCredits,
        error: row?.error ?? (row ? undefined : "账户未返回额度。"),
      };
    });
    writeHostSnapshot(provider, accounts, usages, directory);
    log({
      operation: "sample-result",
      provider,
      accountCount: usages.length,
      failedCount: usages.filter((usage) => usage.error).length,
      capturedAt: result.updatedAt,
      cached: result.cached === true,
    });
    // 界面读取只等待采样；激活由独立、有界的后台任务执行，不拖住 IPC 或另一类 provider。
    return { ...result, activation: { accounts, usages } };
  }
  const activationFlights = new Map<string, Promise<void>>();
  async function accountStatus({
    provider,
    force = false,
  }: {
    provider: string;
    force?: boolean;
  }) {
    if (owner.signal.aborted) throw new Error("Closed");
    let flight = flights.get(provider);
    if (!flight) {
      flight = sample(provider, force)
        .catch((error) => {
          log({ operation: "sample-failed", provider });
          throw error;
        })
        .finally(() => flights.delete(provider));
      flights.set(provider, flight);
    }
    const result = await flight;
    if (result.activation && !activationFlights.has(provider)) {
      const { accounts, usages } = result.activation;
      // 同一真实账户的多个别名必须作为一个任务领取两个窗口，避免并发任务
      // 分别抢到 5h / 7d 后各发送一次。
      const unique = [
        ...new Map(
          accounts.map((account) => [
            resolveAccountId(account.credential) ?? account.credential.access,
            account,
          ]),
        ).values(),
      ];
      const task = mapWithConcurrency(
        unique,
        2,
        async (account) => {
          await activate(
            provider as AccountProvider,
            account,
            usages.find((usage) => usage.accountName === account.name)!,
          );
        },
        owner.signal,
      )
        .then(() => {})
        .catch(() => log({ operation: "activation-failed", provider }))
        .finally(() => activationFlights.delete(provider));
      activationFlights.set(provider, task);
    }
    const { activation: _activation, ...snapshot } = result;
    return snapshot;
  }
  function tick(
    reason: "startup" | "timer" | "wake" | "manual" = "manual",
  ): Promise<void> {
    if (tickFlight) return tickFlight;
    log({ operation: "monitor-tick", reason });
    tickFlight = Promise.allSettled(
      ["openai", "openai-codex", "antigravity"].map((provider) =>
        accountStatus({ provider, force: true }),
      ),
    )
      .then(() => {})
      .finally(() => {
        tickFlight = undefined;
      });
    return tickFlight;
  }

  function emit(flow: Flow, method: string, fields: Record<string, unknown>) {
    flow.events.push({
      method,
      id: `pimac-account:${randomUUID()}`,
      serial: ++flow.serial,
      ...fields,
    });
    flow.events = flow.events.slice(-128);
  }
  function ask(
    flow: Flow,
    dialog: Omit<Dialog, "id">,
    signal: AbortSignal = flow.controller.signal,
  ): Promise<string | boolean | undefined> {
    flow.controller.signal.throwIfAborted();
    signal.throwIfAborted();
    const request = { ...dialog, id: `pimac-account:${randomUUID()}` };
    return new Promise((resolve) => {
      const finish = (value: string | boolean | undefined) => {
        signal.removeEventListener("abort", cancel);
        flow.controller.signal.removeEventListener("abort", cancel);
        flow.requests.delete(request.id);
        resolve(value);
      };
      const cancel = () => finish(undefined);
      signal.addEventListener("abort", cancel, { once: true });
      flow.controller.signal.addEventListener("abort", cancel, { once: true });
      flow.requests.set(request.id, { dialog: request, reply: finish });
    });
  }
  const notify = (flow: Flow, message: string) =>
    emit(flow, "notify", { message });
  /** 宿主对话框不启动线程；每个请求与回复共享同一记录。取消/浏览器回调
   * 都移除同一个请求，新会话默认设置绝不修改正在运行的会话认证。 */
  async function manage(flow: Flow, provider: AccountProvider): Promise<void> {
    const store = storeFor(provider);
    while (!flow.controller.signal.aborted) {
      const state = store.readCodexAccountState();
      const action = await ask(flow, {
        method: "select",
        title: [
          `${provider === "openai" ? "OpenAI ChatGPT" : "Codex legacy"} 多账户管理`,
          "",
          ...state.accounts.map(
            (account) =>
              `${account.name}${account.name === state.activeAccount ? "（新会话默认）" : ""}`,
          ),
          ...(state.accounts.length ? [] : ["尚未登录账户"]),
        ].join("\n"),
        options: [
          "切换账户",
          "刷新额度",
          "登录新账户",
          "删除账户",
          "额度显示设置",
          "自动启动记录",
          "健康检查",
          "关闭",
        ],
      });
      if (!action || action === "关闭") return;
      if (action === "刷新额度") {
        await accountStatus({ provider, force: true });
        notify(flow, "PiMac 已刷新额度，后台独立检查激活。");
      }
      if (action === "切换账户") {
        const name = await ask(flow, {
          method: "select",
          title: "选择新会话默认账户（现有会话不变）",
          options: state.accounts.map((account) => account.name),
        });
        if (typeof name === "string") {
          await store.setActiveAccount(name);
          notify(
            flow,
            `已将 ${name} 设为新会话默认；当前会话切换仍使用额度卡片的切换按钮。`,
          );
        }
      }
      if (action === "额度显示设置") {
        const settings = store.readSettings();
        const selected = await ask(flow, {
          method: "select",
          title: "选择要显示或隐藏额度的账户",
          options: state.accounts.map(
            (account) =>
              `${settings.hiddenAccounts.includes(account.name) ? "○" : "✓"} ${account.name}`,
          ),
        });
        if (typeof selected === "string") {
          const name = selected.replace(/^[○✓]\s+/u, "");
          if (!state.accounts.some((account) => account.name === name))
            throw new Error("Unknown account");
          const hidden = new Set(settings.hiddenAccounts);
          if (hidden.has(name)) hidden.delete(name);
          else hidden.add(name);
          store.writeSettings({ version: 1, hiddenAccounts: [...hidden] });
          await accountStatus({ provider, force: true });
        }
      }
      if (action === "删除账户") {
        const name = await ask(flow, {
          method: "select",
          title: "选择要删除的账户",
          options: state.accounts
            .filter((account) => account.name !== state.activeAccount)
            .map((account) => account.name),
        });
        if (
          typeof name === "string" &&
          (await ask(flow, {
            method: "confirm",
            title: "删除账户",
            message: `确定删除 ${name}？正在使用它的旧会话之后可能无法继续请求。`,
          })) === true
        ) {
          await store.removeAccount(name);
          const settings = store.readSettings();
          store.writeSettings({
            version: 1,
            hiddenAccounts: settings.hiddenAccounts.filter(
              (value) => value !== name,
            ),
          });
        }
      }
      if (action === "自动启动记录") {
        const records = await store.readAutoWarmupRecords();
        notify(
          flow,
          records.length
            ? records
                .slice(-30)
                .map(
                  (record) =>
                    `${new Date(record.timestamp).toLocaleString("zh-CN")} ${record.accountName} ${record.windowKind ?? "5h"} ${record.status === "success" ? "已发送“你好”（未验证计时）" : "失败"}`,
                )
                .join("\n")
            : "尚无自动启动记录。",
        );
      }
      if (action === "健康检查") {
        const snapshot = await accountStatus({ provider, force: true });
        notify(
          flow,
          `PiMac 后台监测运行中；${snapshot.accounts.length} 个可见账户，${snapshot.accounts.filter((account) => account.error).length} 个查询失败。检查原因记录在 pimac-account-monitor.jsonl。`,
        );
      }
      if (action === "登录新账户") {
        const name = await ask(flow, {
          method: "input",
          title: "新账户名称",
          placeholder: "仅允许字母、数字、点、下划线和连字符",
        });
        if (typeof name !== "string") continue;
        if (!/^[A-Za-z0-9._-]{1,64}$/u.test(name)) {
          notify(flow, "账户名称格式无效。");
          continue;
        }
        if (
          state.accounts.some((account) => account.name === name) &&
          (await ask(flow, {
            method: "confirm",
            title: "覆盖账户",
            message: `重新登录并覆盖 ${name}？`,
          })) !== true
        )
          continue;
        const { oauth } = await providerFor(provider);
        const interaction: ProviderAuthInteraction = {
          signal: flow.controller.signal,
          prompt: async (prompt) => {
            const response = await ask(
              flow,
              prompt.type === "select"
                ? {
                    method: "select",
                    title: `[account-usage login] ${prompt.message}`,
                    options: prompt.options.map((option) => option.label),
                  }
                : {
                    method: "input",
                    title: `[account-usage login] ${prompt.message}`,
                    placeholder:
                      "placeholder" in prompt ? prompt.placeholder : undefined,
                  },
              prompt.signal ?? flow.controller.signal,
            );
            if (typeof response !== "string")
              throw new Error("Login cancelled");
            return prompt.type === "select"
              ? (prompt.options.find((option) => option.label === response)
                  ?.id ?? response)
              : response;
          },
          notify: (event) => {
            if (event.type === "auth_url" || event.type === "device_code") {
              emit(flow, "account_auth_url", {
                url:
                  event.type === "auth_url" ? event.url : event.verificationUri,
              });
            }
            notify(
              flow,
              event.type === "auth_url"
                ? `${event.instructions ?? "打开浏览器完成授权"}\n${event.url}`
                : event.type === "device_code"
                  ? `${event.verificationUri}\n${event.userCode}`
                  : event.message,
            );
          },
        };
        const credential = await withDeadline(
          (signal) =>
            oauth.login({ ...interaction, signal }, { getDeviceId: deviceID }),
          flow.controller.signal,
          300_000,
        );
        flow.controller.signal.throwIfAborted();
        await store.saveAccount(name, credential);
        await store.setActiveAccount(name);
        const settings = store.readSettings();
        store.writeSettings({
          version: 1,
          hiddenAccounts: settings.hiddenAccounts.filter(
            (value) => value !== name,
          ),
        });
        notify(flow, `账户 ${name} 已登录并设为新会话默认；现有会话不受影响。`);
      }
    }
  }
  function flowState(flow: Flow) {
    return {
      flowID: flow.id,
      busy: flow.busy,
      requests: [...flow.requests.values()].map((entry) => entry.dialog),
      events: flow.events,
    };
  }
  return {
    accountStatus,
    tick,
    start() {
      if (timer || owner.signal.aborted) return;
      log({ operation: "monitor-start" });
      void tick("startup");
      // 固定节拍不被 UI 查询或会话消息重新延期；唤醒后的第一个 tick 强制采样。
      timer = setInterval(() => {
        void tick("timer");
      }, intervalMs);
      timer.unref();
    },
    control(value: unknown) {
      const input = parseControl(value);
      if (owner.signal.aborted) throw new Error("Closed");
      if (input.operation === "open") {
        if ([...flows.values()].some((flow) => flow.busy))
          throw new Error("Account management already open");
        flows.clear();
        const flow: Flow = {
          id: randomUUID(),
          controller: new AbortController(),
          requests: new Map(),
          events: [],
          serial: 0,
          busy: true,
        };
        flows.set(flow.id, flow);
        const task = manage(flow, input.provider)
          .catch(() =>
            notify(flow, "账户操作未完成，请检查授权、网络或文件权限。"),
          )
          .finally(() => {
            flow.busy = false;
            for (const { reply } of flow.requests.values()) reply(undefined);
            flow.requests.clear();
            flowTasks.delete(task);
          });
        flowTasks.add(task);
        return flowState(flow);
      }
      const flow = flows.get(input.flowID);
      if (!flow) throw new Error("Unknown account flow");
      if (input.operation === "cancel") {
        flow.controller.abort();
        for (const { reply } of flow.requests.values()) reply(undefined);
        flow.busy = false;
        flow.requests.clear();
      } else if (input.operation === "respond") {
        const entry = flow.requests.get(input.id);
        if (!entry) throw new Error("Expired account request");
        const request = entry.dialog;
        if (
          !input.cancelled &&
          (request.method === "select"
            ? !request.options?.includes(input.value ?? "")
            : request.method === "input"
              ? typeof input.value !== "string" || input.value.length > 32768
              : typeof input.confirmed !== "boolean")
        )
          throw new Error("Invalid response");
        entry.reply(
          input.cancelled
            ? undefined
            : request.method === "confirm"
              ? input.confirmed
              : input.value,
        );
      } else if (input.operation !== "poll")
        throw new Error("Unsupported operation");
      return flowState(flow);
    },
    async close() {
      owner.abort();
      if (timer) clearInterval(timer);
      transport.close();
      for (const flow of flows.values()) {
        flow.controller.abort();
        for (const { reply } of flow.requests.values()) reply(undefined);
      }
      await Promise.allSettled([
        ...flights.values(),
        ...activationFlights.values(),
        ...flowTasks,
        ...(tickFlight ? [tickFlight] : []),
      ]);
      log({ operation: "monitor-stop" });
    },
  };
}
