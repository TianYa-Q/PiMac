import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtemp, mkdir } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { join, resolve } from "node:path";
import { createServerGateway } from "./fixtures/protocol-server.mjs";
import { createAccountRuntime } from "../account-runtime.js";
import { createAccountStore } from "../../../extensions/account-usage/store.js";

test("private PiMac account manager and quota queries work without creating a Pi conversation", async () => {
  const temporaryRoot = resolve(import.meta.dirname, "../../../tmp");
  await mkdir(temporaryRoot, { recursive: true });
  const directory = await mkdtemp(join(temporaryRoot, "account-gateway-"));
  const agent = join(directory, "accounts");
  const store = createAccountStore("openai-codex", agent);
  await store.saveAccount("X", {
    type: "oauth",
    accountId: "synthetic-id",
    access: "private-access",
    refresh: "private-refresh",
    expires: Date.now() + 3_600_000,
  });
  await store.setActiveAccount("X");
  let sdkLoads = 0;
  const runtime = createAccountRuntime({
    directory: agent,
    sdk: async () => {
      sdkLoads++;
      throw new Error("No Pi runtime may start in this test");
    },
    fetchImpl: async (input) =>
      Response.json(
        String(input).endsWith("reset-credits")
          ? { available_count: 0 }
          : {
              rate_limit: {
                primary_window: {
                  used_percent: 10,
                  reset_at: Date.now() / 1000 + 18_000,
                  limit_window_seconds: 18_000,
                },
              },
            },
      ),
  });
  const token = "cd".repeat(32);
  const gateway = await createServerGateway({
    token,
    directory: join(directory, "server"),
    piConfig: { enabled: false },
    accountRuntime: runtime,
  });
  try {
    await new Promise<void>((resolve) =>
      gateway.server.listen(0, "127.0.0.1", resolve),
    );
    const address = gateway.server.address();
    assert.ok(address && typeof address === "object");
    const base = `http://127.0.0.1:${address.port}`;
    const post = async (route: string, input: object) => {
      const response = await fetch(base + "/internal/auth/" + route, {
        method: "POST",
        headers: {
          authorization: `Bearer ${token}`,
          "content-type": "application/json",
        },
        body: JSON.stringify(input),
      });
      assert.equal(response.status, 200, await response.clone().text());
      return response.json();
    };
    const opened = await post("account-control", {
      operation: "snapshot",
      provider: "openai-codex",
    });
    const state = JSON.parse(opened.payload);
    assert.deepEqual(
      state.accounts.map((row: { name: string }) => row.name),
      ["X"],
    );
    assert.equal(state.accounts[0].isDefault, true);
    assert.equal(state.requests, undefined);
    const quota = JSON.parse(
      (
        await post("account-status", {
          threadID: "@discovery",
          provider: "openai-codex",
        })
      ).payload,
    );
    assert.equal(quota.accounts[0].primary.remainingPercent, 90);
    assert.doesNotMatch(
      JSON.stringify(quota),
      /private-access|private-refresh/u,
    );
    const checked = JSON.parse(
      (
        await post("account-control", {
          operation: "health",
          provider: "openai-codex",
        })
      ).payload,
    );
    assert.equal(checked.accounts[0].primary.remainingPercent, 90);
    await post("account-monitor-refresh", {});
    assert.equal(sdkLoads, 0);
    const unauthenticated = await fetch(
      base + "/internal/auth/account-control",
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: "{}",
      },
    );
    assert.equal(unauthenticated.status, 401);
  } finally {
    await gateway.close();
    execFileSync("trash", [directory]);
  }
});
