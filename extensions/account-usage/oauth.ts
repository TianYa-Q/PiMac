import type {
  AuthEvent,
  AuthPrompt,
  OAuthAuth,
  OAuthCredential,
  ProviderAuthInteraction,
} from "@earendil-works/pi-ai";
import { builtinProviders } from "@earendil-works/pi-ai/providers/all";
import {
  ExtensionSelectorComponent,
  LoginDialogComponent,
  SettingsManager,
  type ExtensionCommandContext,
} from "@earendil-works/pi-coding-agent";
import { Container } from "@earendil-works/pi-tui";
import type { AccountProvider } from "./types.js";

type LoginResult =
  | { status: "success"; credential: OAuthCredential }
  | { status: "failed"; error: Error };

type InteractiveComponent = Container & {
  handleInput(data: string): void;
  dispose?(): void;
};

export function getCodexOAuth(
  providerId: AccountProvider = "openai-codex",
): OAuthAuth {
  const oauth = builtinProviders().find(
    (provider) => provider.id === providerId,
  )?.auth.oauth;
  if (!oauth)
    throw new Error(`Pi 内置的 ${providerId} OAuth 不可用，请升级到 0.99.1。`);
  return oauth;
}

export async function loginCodexAccount(
  ctx: ExtensionCommandContext,
  ownerSignal: AbortSignal,
  providerId: AccountProvider = "openai-codex",
): Promise<OAuthCredential> {
  const label =
    providerId === "openai"
      ? "OpenAI (ChatGPT subscription)"
      : "OpenAI Codex (legacy)";
  const options = {
    getDeviceId: () => SettingsManager.create(ctx.cwd).getOrCreateDeviceId(),
  };
  // RPC supports standard prompts/notifications, not custom terminal components.
  if (ctx.mode !== "tui") {
    ctx.ui.setStatus("account-usage-login", "active");
    try {
      const credential = await getCodexOAuth(providerId).login(
        {
          signal: ownerSignal,
          async prompt(prompt) {
            ownerSignal.throwIfAborted();
            const title = `[account-usage login] ${prompt.message}`;
            const pending =
              prompt.type === "select"
                ? ctx.ui.select(
                    title,
                    prompt.options.map((option) => option.label),
                  )
                : ctx.ui.input(
                    title,
                    "placeholder" in prompt ? prompt.placeholder : undefined,
                  );
            const value = await raceWithAbort(
              pending,
              prompt.signal,
              ownerSignal,
            );
            if (value === undefined) throw new Error("登录已取消。");
            if (prompt.type === "select")
              return (
                prompt.options.find((option) => option.label === value)?.id ??
                value
              );
            return value;
          },
          notify(event) {
            ctx.ui.notify(
              event.type === "auth_url"
                ? `${event.instructions ?? "打开链接登录"}\n${event.url}`
                : event.type === "device_code"
                  ? `${event.verificationUri}\n${event.userCode}`
                  : event.message,
              "info",
            );
          },
        },
        options,
      );
      return credential;
    } finally {
      // Browser callback completion can win over the manual input prompt. The
      // companion client uses this signal to dismiss that now-obsolete dialog.
      ctx.ui.setStatus("account-usage-login", undefined);
    }
  }
  const result = await ctx.ui.custom<LoginResult>(
    (tui, _theme, _keys, done) => {
      const flowController = new AbortController();
      const finishOnce = finishLoginOnce(done);
      const dialog = new LoginDialogComponent(
        tui,
        providerId,
        (_success, message) => {
          flowController.abort();
          finishOnce({
            status: "failed",
            error: new Error(message ?? "登录已取消。"),
          });
        },
        label,
        `登录新的 ${label} 账户`,
      );
      const view = new OAuthLoginView(dialog, flowController);
      const signal = AbortSignal.any([
        ownerSignal,
        flowController.signal,
        dialog.signal,
      ]);

      // 等组件挂载后再启动 OAuth；登录方式选择、浏览器授权和手动回调输入共用 Pi 原生登录组件。
      queueMicrotask(() => {
        void getCodexOAuth(providerId)
          .login(createOAuthInteraction(view, signal), options)
          .then((credential) => finishOnce({ status: "success", credential }))
          .catch((error: unknown) =>
            finishOnce({ status: "failed", error: asError(error) }),
          );
      });

      return view;
    },
  );

  if (!result) throw new Error("登录已取消。");
  if (result.status === "failed") throw result.error;
  return result.credential;
}

/**
 * OAuth 会先显示登录方式选择器，随后切换到 Pi 原生登录框。
 * 原生登录框负责自动打开浏览器、可点击链接、设备码以及手动回调输入。
 */
class OAuthLoginView extends Container {
  private activeComponent: InteractiveComponent;
  private focusedState = false;

  constructor(
    private readonly dialog: LoginDialogComponent,
    private readonly flowController: AbortController,
  ) {
    super();
    this.activeComponent = dialog;
    this.addChild(dialog);
  }

  get focused(): boolean {
    return this.focusedState;
  }

  set focused(value: boolean) {
    this.focusedState = value;
    this.dialog.focused = value;
  }

  showDialog(): void {
    if (this.activeComponent === this.dialog) return;
    this.activeComponent.dispose?.();
    this.clear();
    this.activeComponent = this.dialog;
    this.dialog.focused = this.focusedState;
    this.addChild(this.dialog);
  }

  select(prompt: Extract<AuthPrompt, { type: "select" }>): Promise<string> {
    return new Promise((resolve, reject) => {
      const labels = prompt.options.map((option) => option.label);
      const selector = new ExtensionSelectorComponent(
        prompt.message,
        labels,
        (label) => {
          const value = prompt.options.find(
            (option) => option.label === label,
          )?.id;
          if (!value) {
            reject(new Error("登录方式无效。"));
            return;
          }
          this.showDialog();
          resolve(value);
        },
        () => {
          this.flowController.abort();
          reject(new Error("登录已取消。"));
        },
      );
      this.clear();
      this.activeComponent = selector;
      this.addChild(selector);
    });
  }

  showManualInput(message: string): Promise<string> {
    this.showDialog();
    return this.dialog.showManualInput(message);
  }

  showPrompt(
    message: string,
    placeholder: string | undefined,
  ): Promise<string> {
    this.showDialog();
    return this.dialog.showPrompt(message, placeholder);
  }

  notify(event: AuthEvent): void {
    this.showDialog();
    switch (event.type) {
      case "auth_url":
        this.dialog.showAuth(event.url, event.instructions);
        break;
      case "device_code":
        this.dialog.showDeviceCode(event);
        this.dialog.showWaiting("等待浏览器授权……");
        break;
      case "info":
        this.dialog.showInfo(event.message, event.links);
        break;
      case "progress":
        this.dialog.showProgress(event.message);
        break;
    }
  }

  handleInput(data: string): void {
    this.activeComponent.handleInput(data);
  }

  dispose(): void {
    this.activeComponent.dispose?.();
  }
}

function createOAuthInteraction(
  view: OAuthLoginView,
  signal: AbortSignal,
): ProviderAuthInteraction {
  return {
    signal,
    prompt: (prompt) => promptForOAuth(view, prompt, signal),
    notify: (event) => notifyOAuthEvent(view, event),
  };
}

async function promptForOAuth(
  view: OAuthLoginView,
  prompt: AuthPrompt,
  ownerSignal: AbortSignal,
): Promise<string> {
  ownerSignal.throwIfAborted();
  if (prompt.type === "select") {
    return raceWithAbort(view.select(prompt), prompt.signal, ownerSignal);
  }

  const pending =
    prompt.type === "manual_code"
      ? view.showManualInput(prompt.message)
      : view.showPrompt(prompt.message, prompt.placeholder);
  return raceWithAbort(pending, prompt.signal, ownerSignal);
}

function notifyOAuthEvent(view: OAuthLoginView, event: AuthEvent): void {
  view.notify(event);
}

function raceWithAbort<T>(
  pending: Promise<T>,
  promptSignal: AbortSignal | undefined,
  ownerSignal: AbortSignal,
): Promise<T> {
  const signal = promptSignal
    ? AbortSignal.any([ownerSignal, promptSignal])
    : ownerSignal;
  if (signal.aborted) return Promise.reject(new Error("登录已取消。"));

  return new Promise((resolve, reject) => {
    const abort = () => reject(new Error("登录已取消。"));
    signal.addEventListener("abort", abort, { once: true });
    void pending.then(resolve, reject).finally(() => {
      signal.removeEventListener("abort", abort);
    });
  });
}

function finishLoginOnce(
  done: (result: LoginResult) => void,
): (result: LoginResult) => void {
  let finished = false;
  return (result) => {
    if (finished) return;
    finished = true;
    done(result);
  };
}

function asError(error: unknown): Error {
  return error instanceof Error ? error : new Error(String(error));
}
