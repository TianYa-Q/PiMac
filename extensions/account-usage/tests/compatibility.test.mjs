import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, rm, stat } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { createJiti } from "jiti";

const root = await mkdtemp(join(tmpdir(), "account-usage-tests-"));
process.env.PI_CODING_AGENT_DIR = root;
process.env.PI_OFFLINE = "1";
const jiti = createJiti(import.meta.url);
const { createAccountStore } = await jiti.import("../store.ts");
const { getCodexOAuth } = await jiti.import("../oauth.ts");
const factory = await jiti.import("../index.ts", { default: true });
const { queryAccountUsage } = await jiti.import("../codex.ts");
const legacy = createAccountStore("openai-codex");
const modern = createAccountStore("openai");
const credential = (access, modern = false) => ({
  type: "oauth",
  access,
  refresh: "synthetic-refresh",
  expires: Date.now() + 3600000,
  accountId: "synthetic-account-id",
  ...(modern
    ? { clientId: "issued-client", scopes: ["chatgpt.tokens.use.direct"] }
    : {}),
});
const requests = [];
const originalFetch = globalThis.fetch;
let usageFixture;

globalThis.fetch = async (url, options = {}) => {
  requests.push({
    url: String(url),
    headers: options.headers,
    body: options.body,
  });
  if (String(url).endsWith("/oauth/token"))
    return Response.json({
      access_token: "modern-refreshed",
      refresh_token: "new-refresh",
      expires_in: 3600,
      scope: "openid chatgpt.tokens.use.direct",
    });
  if (String(url).endsWith("/usage") && usageFixture) {
    const token =
      options.headers.Authorization ?? options.headers.authorization;
    const value = usageFixture.get(token.replace(/^Bearer /u, ""));
    if (!value) throw new Error("Missing synthetic usage fixture");
    return Response.json({
      rate_limit: {
        primary_window: {
          used_percent: 100 - value.short,
          reset_at: Math.floor(Date.now() / 1000) + 18000,
          limit_window_seconds: 18000,
        },
        secondary_window: {
          used_percent: 100 - value.weekly,
          reset_at: Math.floor(Date.now() / 1000) + value.days * 86400,
          limit_window_seconds: 604800,
        },
      },
    });
  }
  if (String(url).endsWith("/usage"))
    return Response.json({
      rate_limit: {
        primary_window: {
          used_percent: 10,
          reset_at: 2000000000,
          limit_window_seconds: 18000,
        },
        secondary_window: {
          used_percent: 20,
          reset_at: 2000000000,
          limit_window_seconds: 604800,
        },
      },
    });
  if (String(url).endsWith("reset-credits"))
    return Response.json({ available_count: 0, credits: [] });
  throw new Error("Unexpected network request");
};

function instance(provider = "openai", apiKey = true, entries = []) {
  const events = new Map();
  const commands = new Map();
  const statuses = [];
  const tokens = new Map();
  const overlays = new Map();
  const mutations = [];
  const ctx = {
    cwd: root,
    mode: "rpc",
    model: {
      provider,
      id: "gpt-test",
      api:
        provider === "openai" ? "openai-responses" : "openai-codex-responses",
    },
    isIdle: () => true,
    abort: () => {
      throw new Error("Should not abort API-key run");
    },
    sessionManager: {
      getSessionId: () => "synthetic-session",
      getEntries: () => entries,
    },
    ui: {
      theme: { fg: (_color, text) => text, bold: (text) => text },
      notify: () => {},
      setStatus: (key, text) => statuses.push([key, text]),
    },
    modelRegistry: {
      hasConfiguredAuth: (model) => apiKey && model.provider === provider,
      isUsingOAuth: () => false,
      getRegisteredProviderConfig: (id) => overlays.get(id),
      registerProvider: (id, config) => {
        overlays.set(id, config);
        mutations.push(id);
      },
      unregisterProvider: (id) => overlays.delete(id),
      setRuntimeApiKey: async (id, token) => tokens.set(id, token),
      removeRuntimeApiKey: async (id) => tokens.delete(id),
      getApiKeyForProvider: async (id) => tokens.get(id),
    },
  };
  factory({
    on: (name, handler) => events.set(name, handler),
    registerCommand: (name, command) => commands.set(name, command),
    appendEntry: (customType, data) =>
      entries.push({ type: "custom", customType, data }),
  });
  return {
    ctx,
    events,
    commands,
    tokens,
    mutations,
    entries,
    status: () =>
      JSON.parse(
        statuses
          .filter(([key, text]) => key === "account-usage-gui" && text)
          .at(-1)[1],
      ),
  };
}

try {
  await test("provider stores isolate identical names and reject legacy grants on OpenAI", async () => {
    await legacy.saveAccount("same", credential("legacy"));
    await legacy.setActiveAccount("same");
    assert.deepEqual(modern.readCodexAccountState().accounts, []);
    await assert.rejects(
      modern.saveAccount("invalid", credential("legacy")),
      /新版 OpenAI/,
    );
    await modern.saveAccount("same", credential("modern", true));
    await modern.setActiveAccount("same");
    assert.equal(
      legacy.readCodexAccountState().accounts[0].credential.access,
      "legacy",
    );
    assert.equal(
      modern.readCodexAccountState().accounts[0].credential.access,
      "modern",
    );
    assert.equal(
      (await stat(join(root, "openai-chatgpt-accounts.json"))).mode & 0o777,
      0o600,
    );
    assert.equal(
      await legacy.claimAutoWarmupWindow("same", 2000000000, Date.now(), 60000),
      true,
    );
    assert.equal(
      await modern.claimAutoWarmupWindow("same", 2000000000, Date.now(), 60000),
      true,
    );
    assert.notEqual(getCodexOAuth("openai"), getCodexOAuth("openai-codex"));
  });

  await test("OpenAI refresh uses dynamic client ID/direct scope, not legacy OAuth", async () => {
    await modern.saveAccount("expired", {
      ...credential("expired", true),
      expires: 0,
    });
    const account = modern
      .readCodexAccountState()
      .accounts.find((a) => a.name === "expired");
    // Pi's refresh drops extra metadata; the extension preserves the account ID.
    await queryAccountUsage(account, new AbortController().signal);
    const request = requests.find((request) =>
      request.url.endsWith("/oauth/token"),
    );
    assert.equal(request.body.get("client_id"), "issued-client");
    assert.equal(request.body.get("resource"), "https://api.openai.com/v1");
    assert.equal(
      modern.readCodexAccountState().accounts.find((a) => a.name === "expired")
        .credential.access,
      "modern-refreshed",
    );
    assert.equal(
      legacy.readCodexAccountState().accounts[0].credential.access,
      "legacy",
    );
    await modern.removeAccount("expired");
  });

  await test("API-key auth is preserved until explicit account selection; model changes isolate auth", async () => {
    const app = instance();
    try {
      await app.events.get("session_start")({ reason: "startup" }, app.ctx);
      assert.equal(app.status().provider, "openai");
      assert.equal(app.status().version, 2);
      assert.equal(app.status().supportsAccountSwitch, true);
      assert.equal(app.status().managesSelectedAuth, false);
      assert.equal(app.tokens.size, 0);
      await app.events.get("before_agent_start")({}, app.ctx);
      assert.equal(app.mutations.length, 0);
      await app.commands.get("accounts").handler("switch same", app.ctx);
      assert.equal(app.tokens.get("openai"), "modern");
      assert.equal(app.tokens.has("openai-codex"), false);
      assert.equal(app.status().managesSelectedAuth, true);
      assert.equal(app.entries.at(-1).data.provider, "openai");
      app.ctx.model = {
        provider: "openai-codex",
        id: "gpt-test",
        api: "openai-codex-responses",
      };
      await app.events.get("model_select")({}, app.ctx);
      assert.equal(app.tokens.has("openai"), false);
      assert.equal(app.tokens.get("openai-codex"), "legacy");
      assert.equal(app.status().provider, "openai-codex");
    } finally {
      await app.events.get("session_shutdown")({}, app.ctx);
    }
    assert.equal(app.tokens.size, 0);
  });

  await test("unmanaged API-key shutdown never removes a foreign runtime credential", async () => {
    const app = instance();
    app.tokens.set("openai", "sk-foreign-runtime");
    try {
      await app.events.get("session_start")({ reason: "startup" }, app.ctx);
      assert.equal(app.status().managesSelectedAuth, false);
    } finally {
      await app.events.get("session_shutdown")({}, app.ctx);
    }
    assert.equal(app.tokens.get("openai"), "sk-foreign-runtime");
  });

  await test("explicit account selection restores the previous runtime API key on shutdown", async () => {
    const app = instance();
    app.tokens.set("openai", "sk-existing-runtime");
    app.ctx.modelRegistry.getProviderAuthStatus = () => ({ source: "runtime" });
    try {
      await app.events.get("session_start")({ reason: "startup" }, app.ctx);
      await app.commands.get("accounts").handler("switch same", app.ctx);
      assert.equal(app.tokens.get("openai"), "modern");
    } finally {
      await app.events.get("session_shutdown")({}, app.ctx);
    }
    assert.equal(app.tokens.get("openai"), "sk-existing-runtime");
  });

  await test("switching providers cancels a pending account activation", async () => {
    const app = instance();
    try {
      await app.events.get("session_start")({ reason: "startup" }, app.ctx);
      const command = app.commands
        .get("accounts")
        .handler("switch same", app.ctx);
      const cancelled = assert.rejects(command, /aborted/);
      app.ctx.model = {
        provider: "openai-codex",
        id: "gpt-test",
        api: "openai-codex-responses",
      };
      await app.events.get("model_select")({}, app.ctx);
      await cancelled;
      assert.equal(app.tokens.has("openai"), false);
      assert.equal(app.tokens.get("openai-codex"), "legacy");
      assert.equal(app.status().provider, "openai-codex");
    } finally {
      await app.events.get("session_shutdown")({}, app.ctx);
    }
  });

  await test("a login-name prompt cannot migrate an operation to another provider", async () => {
    const app = instance();
    let resolveName;
    let inputStarted;
    const started = new Promise((resolve) => {
      inputStarted = resolve;
    });
    app.ctx.ui.select = async () => "登录新账户";
    app.ctx.ui.input = () =>
      new Promise((resolve) => {
        resolveName = resolve;
        inputStarted();
      });
    try {
      await app.events.get("session_start")({ reason: "startup" }, app.ctx);
      const command = app.commands.get("accounts").handler("", app.ctx);
      const cancelled = assert.rejects(command, /已变更/);
      await started;
      app.ctx.model = {
        provider: "openai-codex",
        id: "gpt-test",
        api: "openai-codex-responses",
      };
      await app.events.get("model_select")({}, app.ctx);
      resolveName("new-account");
      await cancelled;
      assert.deepEqual(
        modern.readCodexAccountState().accounts.map((account) => account.name),
        ["same"],
      );
      assert.deepEqual(
        legacy.readCodexAccountState().accounts.map((account) => account.name),
        ["same"],
      );
    } finally {
      await app.events.get("session_shutdown")({}, app.ctx);
    }
  });

  await test("visibility prompts cannot hide an identically named account on another provider", async () => {
    const app = instance();
    let resolveSelection;
    app.ctx.ui.select = () =>
      new Promise((resolve) => {
        resolveSelection = resolve;
      });
    try {
      await app.events.get("session_start")({ reason: "startup" }, app.ctx);
      const command = app.commands.get("usage").handler("settings", app.ctx);
      const cancelled = assert.rejects(command, /已变更/);
      app.ctx.model = {
        provider: "openai-codex",
        id: "gpt-test",
        api: "openai-codex-responses",
      };
      await app.events.get("model_select")({}, app.ctx);
      resolveSelection("✓ same");
      await cancelled;
      assert.deepEqual(modern.readSettings().hiddenAccounts, []);
      assert.deepEqual(legacy.readSettings().hiddenAccounts, []);
    } finally {
      await app.events.get("session_shutdown")({}, app.ctx);
    }
  });

  await test("quota errors stay errors, never copy legacy quotas into OpenAI", async () => {
    const account = modern.readCodexAccountState().accounts[0];
    const result = await queryAccountUsage(
      {
        ...account,
        credential: { ...account.credential, accountId: undefined },
      },
      new AbortController().signal,
    );
    assert.match(result.error, /account ID/);
    assert.equal(result.primary, undefined);
    assert.equal(result.secondary, undefined);
    assert.equal(
      legacy.readCodexAccountState().accounts[0].credential.access,
      "legacy",
    );
  });

  await test("restored modern binding overrides API key only for its provider", async () => {
    const entries = [
      {
        type: "custom",
        customType: "codex-account-selection",
        data: {
          version: 1,
          sessionId: "synthetic-session",
          provider: "openai",
          accountName: "same",
        },
      },
    ];
    const app = instance("openai", true, entries);
    try {
      await app.events.get("session_start")({ reason: "resume" }, app.ctx);
      assert.equal(app.tokens.get("openai"), "modern");
      assert.equal(app.status().activeAccount, "same");
      app.ctx.isIdle = () => false;
      await assert.rejects(
        app.commands.get("accounts").handler("switch same", app.ctx),
        /停止/,
      );
    } finally {
      await app.events.get("session_shutdown")({}, app.ctx);
    }
  });
  async function rotationFixture(run) {
    await modern.saveAccount("spare", credential("spare-token", true));
    await modern.setActiveAccount("same");
    usageFixture = new Map([
      ["modern", { short: 80, weekly: 70, days: 6 }],
      ["spare-token", { short: 80, weekly: 75, days: 6 }],
    ]);
    const app = instance("openai", false);
    app.ctx.isIdle = () => false;
    try {
      await app.events.get("session_start")({ reason: "startup" }, app.ctx);
      await app.commands.get("usage").handler("refresh", app.ctx);
      await run(app);
    } finally {
      await app.events.get("session_shutdown")({}, app.ctx);
      await modern.removeAccount("spare");
      await modern.setActiveAccount("same");
      usageFixture = undefined;
    }
  }

  await test("extension defers low-quota switching while busy, then switches at turn boundary without changing defaults", async () => {
    await rotationFixture(async (app) => {
      usageFixture.get("modern").short = 1;
      await app.commands.get("usage").handler("refresh", app.ctx);
      assert.equal(app.status().activeAccount, "same");
      assert.equal(app.tokens.get("openai"), "modern");
      const result = await app.events.get("turn_end")(
        { outcome: "completed" },
        app.ctx,
      );
      assert.equal(result, undefined);
      assert.equal(app.tokens.get("openai"), "spare-token");
      assert.equal(app.status().activeAccount, "spare");
      assert.equal(app.entries.at(-1).data.accountName, "spare");
      assert.equal(modern.readCodexAccountState().activeAccount, "same");
    });
  });

  await test("extension balances weekly quota pre-run and respects manual-selection cooldown", async () => {
    await rotationFixture(async (app) => {
      Object.assign(usageFixture.get("modern"), { weekly: 50, days: 6 });
      Object.assign(usageFixture.get("spare-token"), { weekly: 40, days: 1 });
      await app.commands.get("usage").handler("refresh", app.ctx);
      await app.events.get("before_agent_start")({}, app.ctx);
      assert.equal(app.status().activeAccount, "spare");
      app.ctx.isIdle = () => true;
      await app.commands.get("accounts").handler("switch same", app.ctx);
      await app.commands.get("usage").handler("refresh", app.ctx);
      assert.equal(app.status().activeAccount, "same");
      usageFixture.get("modern").short = 1;
      await app.commands.get("usage").handler("refresh", app.ctx);
      assert.equal(app.status().activeAccount, "spare"); // Urgency ignores cooldown.
    });
  });

  await test("extension retries a confirmed quota error only once, never retries cancellation or network failure", async () => {
    await rotationFixture(async (app) => {
      app.entries.push({
        type: "message",
        message: { role: "assistant", errorMessage: "429 usage limit reached" },
      });
      usageFixture.get("modern").short = 1;
      const event = { outcome: "error", context: { canContinue: true } };
      assert.deepEqual(
        await app.events.get("agent_before_settle")(event, app.ctx),
        { continue: true },
      );
      assert.equal(app.status().activeAccount, "spare");
      usageFixture.get("spare-token").short = 1;
      usageFixture.get("modern").short = 80;
      assert.equal(
        await app.events.get("agent_before_settle")(event, app.ctx),
        undefined,
      );
      assert.equal(app.status().activeAccount, "spare");
      assert.equal(
        await app.events.get("agent_before_settle")(
          { ...event, outcome: "aborted" },
          app.ctx,
        ),
        undefined,
      );
      await app.events.get("before_agent_start")({}, app.ctx);
      app.entries.push({
        type: "message",
        message: { role: "assistant", errorMessage: "network unavailable" },
      });
      assert.equal(
        await app.events.get("agent_before_settle")(event, app.ctx),
        undefined,
      );
    });
  });

  await test("failed automatic activation rolls back runtime auth and leaves the session binding intact", async () => {
    await rotationFixture(async (app) => {
      usageFixture.get("modern").short = 1;
      await app.commands.get("usage").handler("refresh", app.ctx);
      const resolve = app.ctx.modelRegistry.getApiKeyForProvider;
      app.ctx.modelRegistry.getApiKeyForProvider = async (id) => {
        const token = await resolve(id);
        return token === "spare-token" ? "not-applied" : token;
      };
      await app.events.get("turn_end")({ outcome: "completed" }, app.ctx);
      assert.equal(app.tokens.get("openai"), "modern");
      assert.equal(app.status().activeAccount, "same");
      assert.equal(app.entries.at(-1).data.accountName, "same");
    });
  });

  await test("automatic rotation is session-local and does not opt an API-key session into managed auth", async () => {
    await rotationFixture(async (app) => {
      const other = instance("openai", false);
      const apiKey = instance("openai", true);
      other.ctx.isIdle = () => false;
      other.ctx.sessionManager.getSessionId = () => "other-session";
      apiKey.tokens.set("openai", "sk-untouched");
      try {
        await other.events.get("session_start")(
          { reason: "startup" },
          other.ctx,
        );
        await apiKey.events.get("session_start")(
          { reason: "startup" },
          apiKey.ctx,
        );
        usageFixture.get("modern").short = 1;
        await app.commands.get("usage").handler("refresh", app.ctx);
        await app.events.get("turn_end")({ outcome: "completed" }, app.ctx);
        await apiKey.commands.get("usage").handler("refresh", apiKey.ctx);
        await apiKey.events.get("before_agent_start")({}, apiKey.ctx);
        assert.equal(app.tokens.get("openai"), "spare-token");
        assert.equal(other.tokens.get("openai"), "modern");
        assert.equal(apiKey.tokens.get("openai"), "sk-untouched");
        assert.equal(apiKey.status().managesSelectedAuth, false);
      } finally {
        await other.events.get("session_shutdown")({}, other.ctx);
        await apiKey.events.get("session_shutdown")({}, apiKey.ctx);
      }
    });
  });

  await test("provider changes await and cancel an in-flight automatic activation before clearing auth", async () => {
    await rotationFixture(async (app) => {
      usageFixture.get("modern").short = 1;
      await app.commands.get("usage").handler("refresh", app.ctx);
      let resume, started;
      const applying = new Promise((resolve) => {
        started = resolve;
      });
      const install = app.ctx.modelRegistry.setRuntimeApiKey;
      app.ctx.modelRegistry.setRuntimeApiKey = async (id, token) => {
        if (token === "spare-token") {
          started();
          await new Promise((resolve) => {
            resume = resolve;
          });
        }
        await install(id, token);
      };
      const rotation = app.events.get("turn_end")(
        { outcome: "completed" },
        app.ctx,
      );
      await applying;
      app.ctx.model = {
        provider: "openai-codex",
        id: "gpt-test",
        api: "openai-codex-responses",
      };
      const changed = app.events.get("model_select")({}, app.ctx);
      resume();
      await Promise.all([rotation, changed]);
      assert.equal(app.tokens.has("openai"), false);
      assert.equal(app.tokens.get("openai-codex"), "legacy");
      assert.equal(app.status().provider, "openai-codex");
      assert.equal(
        app.entries
          .filter((entry) => entry.type === "custom")
          .some(
            (entry) =>
              entry.data.provider === "openai" &&
              entry.data.accountName === "spare",
          ),
        false,
      );
    });
  });

  await test("automatic switching preserves unmanaged legacy API keys too", async () => {
    const app = instance("openai-codex", true);
    app.tokens.set("openai-codex", "sk-legacy-key");
    try {
      await app.events.get("session_start")({ reason: "startup" }, app.ctx);
      await app.events.get("before_agent_start")({}, app.ctx);
      assert.equal(app.status().managesSelectedAuth, false);
      assert.equal(app.tokens.get("openai-codex"), "sk-legacy-key");
    } finally {
      await app.events.get("session_shutdown")({}, app.ctx);
    }
    assert.equal(app.tokens.get("openai-codex"), "sk-legacy-key");
  });
} finally {
  globalThis.fetch = originalFetch;
  await rm(root, { recursive: true, force: true });
}
