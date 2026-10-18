import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { resolve, join } from "node:path";
import { createJiti } from "jiti";

// Pi 扩展的迁移后契约：只有会话认证/切换/安全轮换，不再查询额度或发送激活请求。
const temporaryRoot = resolve(import.meta.dirname, "../../../tmp");
await mkdir(temporaryRoot, { recursive: true });
const root = await mkdtemp(join(temporaryRoot, "session-accounts-"));
process.env.PI_CODING_AGENT_DIR = root;
process.env.PI_OFFLINE = "1";
const jiti = createJiti(import.meta.url);
const { createAccountStore } = await jiti.import("../store.ts");
const { writeHostSnapshot, readHostSnapshot } = await jiti.import(
  "../host-snapshot.ts",
);
const factory = await jiti.import("../index.ts", { default: true });
const credential = (id) => ({
  type: "oauth",
  access: `synthetic-${id}`,
  refresh: "synthetic-refresh",
  expires: Date.now() + 3600000,
  accountId: id,
});

function instance(provider = "openai-codex", apiKey = false, entries = []) {
  const events = new Map(),
    commands = new Map(),
    statuses = [],
    notices = [],
    tokens = new Map(),
    overlays = new Map();
  const appended = [];
  const ctx = {
    cwd: root,
    mode: "rpc",
    model: { provider, id: "test", api: "openai-responses" },
    isIdle: () => true,
    abort: () => {
      ctx.aborts++;
    },
    aborts: 0,
    sessionManager: {
      getSessionId: () => "synthetic-session",
      getEntries: () => entries,
    },
    ui: {
      notify: (message) => notices.push(message),
      setStatus: (key, text) => statuses.push([key, text]),
    },
    modelRegistry: {
      hasConfiguredAuth: () => apiKey,
      isUsingOAuth: () => false,
      getRegisteredProviderConfig: (id) => overlays.get(id),
      registerProvider: (id, config) => overlays.set(id, config),
      unregisterProvider: (id) => overlays.delete(id),
      setRuntimeApiKey: async (id, token) => tokens.set(id, token),
      removeRuntimeApiKey: async (id) => tokens.delete(id),
      getApiKeyForProvider: async (id) => tokens.get(id),
    },
  };
  factory({
    on: (name, handler) => events.set(name, handler),
    registerCommand: (name, command) => commands.set(name, command),
    appendEntry: (customType, data) => appended.push({ customType, data }),
  });
  return {
    ctx,
    events,
    commands,
    tokens,
    overlays,
    appended,
    notices,
    statuses,
    status() {
      return JSON.parse(
        statuses
          .filter(([key, value]) => key === "account-usage-gui" && value)
          .at(-1)[1],
      );
    },
    start() {
      return events.get("session_start")({ reason: "startup" }, ctx);
    },
    close() {
      return events.get("session_shutdown")({}, ctx);
    },
  };
}

try {
  const legacy = createAccountStore("openai-codex"),
    modern = createAccountStore("openai");
  await legacy.saveAccount("X", credential("legacy-X"));
  await legacy.saveAccount("Y", credential("legacy-Y"));
  await legacy.setActiveAccount("X");
  await modern.saveAccount("X", {
    ...credential("modern-X"),
    clientId: "issued-client",
    scopes: ["chatgpt.tokens.use.direct"],
  });
  await modern.setActiveAccount("X");

  await test("session startup and lifecycle never query quotas or send activation, even with full host snapshots", async () => {
    const originalFetch = globalThis.fetch;
    globalThis.fetch = () => {
      throw new Error("Session extension must not query the network");
    };
    const accounts = legacy.readCodexAccountState().accounts;
    writeHostSnapshot(
      "openai-codex",
      accounts,
      accounts.map((account) => ({
        accountName: account.name,
        capturedAt: Date.now(),
        primary: {
          remainingPercent: 100,
          windowSeconds: 18000,
          resetAt: Date.now() / 1000 + 18000,
        },
      })),
      root,
    );
    const app = instance();
    try {
      await app.start();
      await app.events.get("turn_end")({ outcome: "completed" }, app.ctx);
      await app.events.get("agent_settled")({}, app.ctx);
      assert.equal(app.status().activeAccount, "X");
      assert.equal(app.status().selectionOnly, true);
      assert.deepEqual(app.status().accounts, []);
      assert.equal(app.commands.has("usage"), false);
      await app.commands.get("accounts").handler("", app.ctx);
      assert.match(app.notices.at(-1), /已迁至 PiMac/u);
    } finally {
      await app.close();
      globalThis.fetch = originalFetch;
    }
  });

  await test("native API-key authentication stays untouched until an explicit session account switch", async () => {
    const app = instance("openai", true);
    try {
      await app.start();
      assert.equal(app.tokens.size, 0);
      assert.equal(app.status().managesSelectedAuth, false);
      await app.commands.get("accounts").handler("switch X", app.ctx);
      assert.equal(app.tokens.get("openai"), "synthetic-modern-X");
      assert.equal(app.tokens.has("openai-codex"), false);
    } finally {
      await app.close();
    }
    assert.equal(app.tokens.size, 0);
    assert.equal(app.overlays.size, 0);
  });

  await test("switching a live session never changes future default or other session bindings", async () => {
    const first = instance(),
      second = instance();
    try {
      await first.start();
      await second.start();
      await first.commands.get("accounts").handler("switch Y", first.ctx);
      assert.equal(first.status().activeAccount, "Y");
      assert.equal(second.status().activeAccount, "X");
      assert.equal(legacy.readCodexAccountState().activeAccount, "X");
      assert.match(first.notices.at(-1), /仅当前会话/u);
    } finally {
      await first.close();
      await second.close();
    }
  });

  await test("a managed resumed binding overrides defaults but never crosses providers", async () => {
    const entries = [
      {
        type: "custom",
        customType: "codex-account-selection",
        data: {
          version: 1,
          provider: "openai-codex",
          sessionId: "synthetic-session",
          accountName: "Y",
        },
      },
    ];
    const app = instance("openai-codex", false, entries),
      other = instance("openai", false, entries);
    try {
      await app.start();
      await other.start();
      assert.equal(app.status().activeAccount, "Y");
      assert.equal(other.status().activeAccount, "X");
      assert.equal(other.tokens.get("openai"), "synthetic-modern-X");
    } finally {
      await app.close();
      await other.close();
    }
  });

  await test("low quota can rotate at a safe turn boundary using host telemetry, not a new network query", async () => {
    const accounts = legacy.readCodexAccountState().accounts;
    writeHostSnapshot(
      "openai-codex",
      accounts,
      accounts.map((account) => ({
        accountName: account.name,
        capturedAt: Date.now(),
        primary: {
          remainingPercent: account.name === "X" ? 1 : 80,
          windowSeconds: 18000,
          resetAt: Date.now() / 1000 + 10000,
        },
        secondary: {
          remainingPercent: 80,
          windowSeconds: 604800,
          resetAt: Date.now() / 1000 + 300000,
        },
      })),
      root,
    );
    const app = instance();
    try {
      await app.start();
      assert.equal(app.status().activeAccount, "Y");
      assert.equal(legacy.readCodexAccountState().activeAccount, "X");
    } finally {
      await app.close();
    }
  });

  await test("confirmed quota error uses a fresh host spare once even before current quota catches up", async () => {
    const accounts = legacy.readCodexAccountState().accounts;
    writeHostSnapshot(
      "openai-codex",
      accounts,
      accounts.map((account) => ({
        accountName: account.name,
        capturedAt: Date.now(),
        primary: {
          remainingPercent: 90,
          windowSeconds: 18000,
          resetAt: Date.now() / 1000 + 10000,
        },
      })),
      root,
    );
    const app = instance("openai-codex", false, [
      {
        type: "message",
        message: { role: "assistant", errorMessage: "usage limit" },
      },
    ]);
    try {
      await app.start();
      const error = { outcome: "error", context: { canContinue: true } };
      assert.deepEqual(
        await app.events.get("agent_before_settle")(error, app.ctx),
        { continue: true },
      );
      assert.equal(app.status().activeAccount, "Y");
      assert.equal(
        await app.events.get("agent_before_settle")(error, app.ctx),
        undefined,
      );
    } finally {
      await app.close();
    }
  });

  await test("replacement identity invalidates disk telemetry instead of inheriting same-name quota", async () => {
    const before = legacy.readCodexAccountState().accounts;
    await legacy.saveAccount("X", credential("replacement"));
    assert.notDeepEqual(before, legacy.readCodexAccountState().accounts);
    assert.deepEqual(
      readHostSnapshot(
        "openai-codex",
        legacy.readCodexAccountState().accounts,
        root,
      ),
      [],
    );
  });

  await test("missing or corrupt host telemetry does not become a fake quota or cancel valid auth", async () => {
    await writeFile(join(root, "pimac-openai-codex-quota.json"), "{invalid", {
      mode: 0o600,
    });
    const app = instance();
    try {
      await app.start();
      await app.events.get("before_agent_start")({}, app.ctx);
      await app.events.get("turn_start")({}, app.ctx);
      assert.ok(
        app.notices.some((message) =>
          message.includes("读取 PiMac 额度快照失败"),
        ),
      );
      assert.equal(app.ctx.aborts, 0);
      assert.equal(app.tokens.get("openai-codex"), "synthetic-replacement");
    } finally {
      await app.close();
    }
  });
} finally {
  execFileSync("trash", [root]);
}
