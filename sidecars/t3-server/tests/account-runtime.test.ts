import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { join, resolve } from "node:path";
import { createAccountRuntime, activationReason } from "../account-runtime.js";
import { createAccountStore } from "../../../extensions/account-usage/store.js";
import { readHostSnapshot } from "../../../extensions/account-usage/host-snapshot.js";
import type { AccountSDK } from "../../../extensions/account-usage/host-types.js";

const root = resolve(import.meta.dirname, "../../../tmp");
const credential = (id = "account-1") => ({
  type: "oauth" as const,
  accountId: id,
  access: `private-${id}`,
  refresh: "private-refresh",
  expires: Date.now() + 3_600_000,
});
async function fixture() {
  await mkdir(root, { recursive: true });
  const directory = await mkdtemp(join(root, "account-runtime-"));
  let now = Date.now(),
    fail = false,
    sends = 0,
    queries = 0,
    refreshes = 0;
  const store = createAccountStore("openai-codex", directory);
  await store.saveAccount("X", credential());
  await store.setActiveAccount("X");
  let reset = Math.floor(now / 1000) + 18_000;
  const sdk = {
    normalizeContext: (value: unknown) => value,
    providers: [
      {
        id: "openai-codex",
        getModels: () => [{ id: "gpt-5.6-luna" }],
        auth: {
          oauth: {
            refresh: async () => {
              refreshes++;
              return credential();
            },
            login: async () => credential("login"),
          },
        },
        streamSimple: () => ({
          result: async () => {
            sends++;
            return { stopReason: fail ? "error" : "stop" };
          },
        }),
      },
    ],
  } as unknown as AccountSDK;
  const fetchImpl: typeof fetch = async (input) => {
    if (String(input).endsWith("reset-credits"))
      return Response.json({ available_count: 0 });
    queries++;
    return Response.json({
      rate_limit: {
        primary_window: {
          used_percent: 0,
          reset_at: reset,
          limit_window_seconds: 18_000,
        },
        secondary_window: {
          used_percent: 0,
          reset_at: Math.floor(now / 1000) + 604_800,
          limit_window_seconds: 604_800,
        },
      },
    });
  };
  const create = (overrides: Parameters<typeof createAccountRuntime>[0] = {}) =>
    createAccountRuntime({
      directory,
      sdk: async () => sdk,
      now: () => now,
      fetchImpl,
      ...overrides,
    });
  return {
    directory,
    store,
    sdk,
    create,
    get sends() {
      return sends;
    },
    get queries() {
      return queries;
    },
    get refreshes() {
      return refreshes;
    },
    advance(ms: number) {
      now += ms;
    },
    setFail(value: boolean) {
      fail = value;
    },
    setReset(value: number) {
      reset = value;
    },
    async cleanup() {
      execFileSync("trash", [directory]);
    },
  };
}
async function settle(predicate: () => boolean | Promise<boolean>) {
  for (let attempt = 0; attempt < 200; attempt++) {
    try {
      if (await predicate()) return;
    } catch (error) {
      if (
        !(error instanceof Error && "code" in error && error.code === "ELOCKED")
      )
        throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 2));
  }
  assert.fail("Background work did not settle");
}

test("full quota with an active countdown is not an unused window; expired full windows can recover", () => {
  const now = Date.now();
  const window = {
    remainingPercent: 100,
    resetAt: now / 1000 + 18_000,
    windowSeconds: 18_000,
  };
  assert.equal(activationReason(window, now, now, 18_000), "eligible");
  assert.equal(
    activationReason(
      { ...window, resetAt: now / 1000 + 16_000 },
      now,
      now,
      18_000,
    ),
    "countdown-active",
  );
  assert.equal(
    activationReason(
      { ...window, resetAt: now / 1000 - 100 },
      now,
      now,
      18_000,
    ),
    "eligible",
  );
  assert.equal(
    activationReason({ ...window, remainingPercent: 99 }, now, now, 18_000),
    "not-full",
  );
  assert.equal(activationReason(window, now - 181_000, now, 18_000), "stale");
  assert.equal(activationReason(undefined, now, now, 18_000), "unknown-window");
});

test("PiMac samples and activates without a Pi session; UI and monitor coalesce and two windows send once", async () => {
  const f = await fixture();
  const runtime = f.create();
  try {
    await Promise.all([
      runtime.accountStatus({ provider: "openai-codex" }),
      runtime.accountStatus({ provider: "openai-codex" }),
    ]);
    await settle(
      async () => (await f.store.readAutoWarmupRecords()).length === 2,
    );
    assert.equal(f.queries, 1);
    assert.equal(f.sends, 1);
    await runtime.tick();
    await settle(() => f.queries === 2);
    assert.equal(f.sends, 1);
    assert.equal(
      readHostSnapshot(
        "openai-codex",
        f.store.readCodexAccountState().accounts,
        f.directory,
      ).length,
      1,
    );
    await settle(async () =>
      (
        await readFile(join(f.directory, "pimac-account-monitor.jsonl"), "utf8")
      ).includes("claimed-or-cooldown"),
    );
    const log = await readFile(
      join(f.directory, "pimac-account-monitor.jsonl"),
      "utf8",
    );
    assert.match(log, /activation-check/u);
    assert.match(log, /claimed-or-cooldown/u);
    assert.doesNotMatch(log, /private-account|private-refresh|Bearer/u);
  } finally {
    await runtime.close();
    await f.cleanup();
  }
});

test("failed activation retries the SAME reset after the lease and persists successful dedupe over restart", async () => {
  const f = await fixture();
  let runtime = f.create();
  try {
    f.setFail(true);
    await runtime.accountStatus({ provider: "openai-codex" });
    await settle(
      async () => (await f.store.readAutoWarmupRecords()).length === 2,
    );
    f.advance(121_000);
    f.setFail(false);
    await runtime.accountStatus({ provider: "openai-codex", force: true });
    await settle(
      async () => (await f.store.readAutoWarmupRecords()).length === 4,
    );
    assert.equal(f.sends, 2);
    await runtime.close();
    runtime = f.create();
    await runtime.accountStatus({ provider: "openai-codex", force: true });
    await new Promise((resolve) => setTimeout(resolve, 30));
    assert.equal(f.sends, 2);
  } finally {
    await runtime.close();
    await f.cleanup();
  }
});

test("monitor cadence is independent of UI calls and hidden accounts never query or activate", async () => {
  const f = await fixture();
  const runtime = f.create({ intervalMs: 15 });
  try {
    f.store.writeSettings({ version: 1, hiddenAccounts: ["X"] });
    runtime.start();
    await new Promise((resolve) => setTimeout(resolve, 40));
    assert.equal(f.queries, 0);
    assert.equal(f.sends, 0);
    f.store.writeSettings({ version: 1, hiddenAccounts: [] });
    await settle(() => f.queries >= 2 && f.sends === 1);
    assert.equal(f.sends, 1);
  } finally {
    await runtime.close();
    await f.cleanup();
  }
});

test("host refreshes managed grants with official OAuth and never rewrites native auth", async () => {
  const f = await fixture();
  const runtime = f.create();
  try {
    await f.store.saveAccount("X", { ...credential(), expires: 1 });
    const native = JSON.stringify({
      openai: { type: "api_key", key: "private-api-key" },
      "openai-codex": { ...credential(), access: "fresh-native-grant" },
    });
    await writeFile(join(f.directory, "auth.json"), native, { mode: 0o600 });
    await runtime.accountStatus({ provider: "openai-codex" });
    assert.equal(f.refreshes, 1);
    assert.ok(
      f.store.readCodexAccountState().accounts[0].credential.expires >
        Date.now(),
    );
    assert.equal(
      await readFile(join(f.directory, "auth.json"), "utf8"),
      native,
    );
  } finally {
    await runtime.close();
    await f.cleanup();
  }
});

test("a 401 refreshes a future-dated managed grant once instead of waiting hours for expiry", async () => {
  const f = await fixture();
  let refreshes = 0;
  let attempts = 0;
  const sdk = {
    ...f.sdk,
    providers: [
      {
        ...f.sdk.providers[0],
        auth: {
          oauth: {
            ...f.sdk.providers[0].auth.oauth,
            refresh: async () => {
              refreshes++;
              return { ...credential(), access: "after-401" };
            },
          },
        },
      },
    ],
  } as unknown as AccountSDK;
  const runtime = f.create({
    sdk: async () => sdk,
    fetchImpl: async (input) => {
      if (String(input).endsWith("reset-credits"))
        return Response.json({ available_count: 0 });
      if (++attempts === 1)
        return new Response("private provider body", { status: 401 });
      return Response.json({
        rate_limit: {
          primary_window: {
            used_percent: 10,
            reset_at: Date.now() / 1000 + 18000,
            limit_window_seconds: 18000,
          },
        },
      });
    },
  });
  try {
    const result = await runtime.accountStatus({ provider: "openai-codex" });
    assert.equal(result.accounts[0].error, undefined);
    assert.equal(result.accounts[0].primary?.remainingPercent, 90);
    assert.equal(refreshes, 1);
    assert.equal(attempts, 2);
    assert.equal(
      f.store.readCodexAccountState().accounts[0].credential.access,
      "after-401",
    );
  } finally {
    await runtime.close();
    await f.cleanup();
  }
});

test("a replacement login during query cannot receive the previous identity quota or activation", async () => {
  const f = await fixture();
  let release!: () => void;
  const gate = new Promise<void>((resolve) => {
    release = resolve;
  });
  let entered = false;
  const runtime = f.create({
    fetchImpl: async () => {
      entered = true;
      await gate;
      return Response.json({
        rate_limit: {
          primary_window: {
            used_percent: 0,
            reset_at: Date.now() / 1000 + 18000,
            limit_window_seconds: 18000,
          },
        },
      });
    },
  });
  try {
    const query = runtime.accountStatus({ provider: "openai-codex" });
    await settle(() => entered);
    await f.store.saveAccount("X", credential("replacement"));
    release();
    await assert.rejects(query, /identity changed/u);
    assert.equal(f.sends, 0);
    assert.deepEqual(
      readHostSnapshot(
        "openai-codex",
        f.store.readCodexAccountState().accounts,
        f.directory,
      ),
      [],
    );
  } finally {
    release();
    await runtime.close();
    await f.cleanup();
  }
});

test("activation dedupe follows account identity: aliases share a claim and a replacement login can activate", async () => {
  const f = await fixture();
  const runtime = f.create();
  try {
    await f.store.saveAccount("Alias", credential());
    await runtime.accountStatus({ provider: "openai-codex" });
    await settle(
      async () => (await f.store.readAutoWarmupRecords()).length === 2,
    );
    assert.equal(f.sends, 1);
    await f.store.saveAccount("X", credential("replacement"));
    await runtime.accountStatus({ provider: "openai-codex", force: true });
    await settle(() => f.sends === 2);
    assert.equal(f.sends, 2);
  } finally {
    await runtime.close();
    await f.cleanup();
  }
});

test("host login supplies a persistent official OAuth device ID without a Pi session", async () => {
  const f = await fixture();
  const deviceIDs: string[] = [];
  const sdk = {
    ...f.sdk,
    providers: [
      {
        ...f.sdk.providers[0],
        auth: {
          oauth: {
            ...f.sdk.providers[0].auth.oauth,
            login: async (
              _interaction: unknown,
              options: { getDeviceId: () => string },
            ) => {
              deviceIDs.push(options.getDeviceId());
              return credential("logged-in");
            },
          },
        },
      },
    ],
  } as unknown as AccountSDK;
  const runtime = f.create({ sdk: async () => sdk });
  try {
    const state = await runtime.control({
      operation: "login",
      provider: "openai-codex",
      name: "Login",
    });
    assert.ok("flowID" in state);
    await settle(
      () => f.store.readCodexAccountState().activeAccount === "Login",
    );
    assert.match(deviceIDs[0]!, /^[0-9a-f-]{36}$/u);
    assert.equal(
      JSON.parse(
        await readFile(join(f.directory, "pimac-account-device.json"), "utf8"),
      ).deviceID,
      deviceIDs[0],
    );
    assert.doesNotMatch(
      JSON.stringify(
        await runtime.control({ operation: "poll", flowID: state.flowID }),
      ),
      /private-logged-in|private-refresh/u,
    );
    await runtime.control({ operation: "cancel", flowID: state.flowID });
  } finally {
    await runtime.close();
    await f.cleanup();
  }
});

test("workspace actions persist directly without dialog cycles, protect defaults, and separate providers", async () => {
  const f = await fixture();
  const runtime = f.create();
  try {
    await f.store.saveAccount("Y", credential("second"));
    const input = { provider: "openai-codex" };
    let state = await runtime.control({ ...input, operation: "snapshot" });
    assert.ok("accounts" in state);
    assert.deepEqual(
      state.accounts.map((row) => row.name),
      ["X", "Y"],
    );
    assert.equal("requests" in state, false);
    assert.equal(f.queries, 0);
    state = await runtime.control({
      ...input,
      operation: "set-default",
      name: "Y",
    });
    assert.ok("accounts" in state);
    assert.equal(
      state.accounts.find((row) => row.name === "Y")?.isDefault,
      true,
    );
    assert.equal(f.store.readCodexAccountState().activeAccount, "Y");
    await assert.rejects(
      runtime.control({ ...input, operation: "delete", name: "Y" }),
    );
    state = await runtime.control({
      ...input,
      operation: "visibility",
      name: "X",
      visible: false,
    });
    assert.ok("accounts" in state);
    assert.equal(
      state.accounts.find((row) => row.name === "X")?.isVisible,
      false,
    );
    assert.deepEqual(f.store.readSettings().hiddenAccounts, ["X"]);
    await runtime.control({ ...input, operation: "refresh" });
    assert.equal(f.queries, 1);
    state = await runtime.control({ ...input, operation: "snapshot" });
    assert.ok("accounts" in state);
    assert.equal(
      state.accounts.find((row) => row.name === "Y")?.primary?.remainingPercent,
      100,
    );
    assert.equal(state.accounts.find((row) => row.name === "X")?.primary, null);
    await settle(
      async () => (await f.store.readAutoWarmupRecords()).length === 2,
    );
    state = await runtime.control({ ...input, operation: "snapshot" });
    assert.ok("records" in state);
    assert.equal(state.records.length, 2);
    assert.equal(state.records[0]?.status, "success");
    state = await runtime.control({ ...input, operation: "delete", name: "X" });
    assert.ok("accounts" in state);
    assert.deepEqual(
      state.accounts.map((row) => row.name),
      ["Y"],
    );
    assert.deepEqual(f.store.readSettings().hiddenAccounts, []);
    const other = await runtime.control({
      operation: "snapshot",
      provider: "openai",
    });
    assert.ok("accounts" in other);
    assert.deepEqual(other.accounts, []);
    await assert.rejects(
      runtime.control({ ...input, operation: "set-default", name: "unknown" }),
    );
    await assert.rejects(
      runtime.control({
        ...input,
        operation: "visibility",
        name: "Y",
        visible: "false",
      }),
    );
    await assert.rejects(
      runtime.control({ ...input, operation: "login", name: "Y" }),
    );
    assert.doesNotMatch(
      JSON.stringify(state),
      /private-|refresh_token|access_token/u,
    );
  } finally {
    await runtime.close();
    await f.cleanup();
  }
});

test("official OAuth prompts stay in a login flow and cancellation leaves credentials unchanged", async () => {
  const f = await fixture();
  const sdk = {
    ...f.sdk,
    providers: [
      {
        ...f.sdk.providers[0],
        auth: {
          oauth: {
            ...f.sdk.providers[0]!.auth.oauth,
            login: async (interaction: {
              prompt: (input: unknown) => Promise<string>;
            }) => {
              const choice = await interaction.prompt({
                type: "select",
                message: "Choose authorization",
                options: [{ id: "browser", label: "Browser" }],
              });
              assert.equal(choice, "browser");
              await interaction.prompt({
                type: "input",
                message: "Paste callback",
              });
              return credential("authorized");
            },
          },
        },
      },
    ],
  } as unknown as AccountSDK;
  const runtime = f.create({ sdk: async () => sdk });
  try {
    let state = await runtime.control({
      operation: "login",
      provider: "openai-codex",
      name: "New",
    });
    assert.ok("flowID" in state);
    const flowID = state.flowID;
    await settle(async () => {
      state = await runtime.control({ operation: "poll", flowID });
      return "requests" in state && state.requests.length === 1;
    });
    assert.ok("requests" in state);
    await assert.rejects(
      runtime.control({
        operation: "respond",
        flowID,
        id: state.requests[0]!.id,
        value: "injected",
      }),
    );
    await runtime.control({
      operation: "respond",
      flowID,
      id: state.requests[0]!.id,
      value: "Browser",
    });
    await settle(async () => {
      state = await runtime.control({ operation: "poll", flowID });
      return "requests" in state && state.requests[0]?.method === "input";
    });
    state = await runtime.control({ operation: "cancel", flowID });
    assert.ok("outcome" in state);
    assert.equal(state.outcome, "cancelled");
    assert.equal(state.requests.length, 0);
    await settle(async () => {
      const terminal = await runtime.control({ operation: "poll", flowID });
      return "busy" in terminal && !terminal.busy;
    });
    assert.deepEqual(
      f.store.readCodexAccountState().accounts.map((row) => row.name),
      ["X"],
    );
  } finally {
    await runtime.close();
    await f.cleanup();
  }
});
