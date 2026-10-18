import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, mkdir } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { join, resolve } from "node:path";
import { createAccountRuntime } from "../account-runtime.js";
import { createAccountStore } from "../../../extensions/account-usage/store.js";
import type { AccountSDK } from "../../../extensions/account-usage/host-types.js";

test("reauthorization replaces only the chosen grant, preserves default, and publishes failures separately", async () => {
  const root = resolve(import.meta.dirname, "../../../tmp");
  await mkdir(root, { recursive: true });
  const directory = await mkdtemp(join(root, "workspace-reauthorize-"));
  const store = createAccountStore("openai-codex", directory);
  const credential = (access: string) => ({
    type: "oauth" as const,
    accountId: access,
    access,
    refresh: "private-refresh",
    expires: Date.now() + 3600000,
  });
  await store.saveAccount("X", credential("private-original"));
  await store.saveAccount("Y", credential("private-default"));
  await store.setActiveAccount("Y");
  let fail = false;
  const sdk = {
    providers: [
      {
        id: "openai-codex",
        auth: {
          oauth: {
            login: async () => {
              if (fail) throw new Error("private-secret-error");
              return credential("private-replaced");
            },
          },
        },
      },
    ],
  } as unknown as AccountSDK;
  const runtime = createAccountRuntime({ directory, sdk: async () => sdk });
  try {
    async function finish(flowID: string) {
      for (let attempt = 0; attempt < 200; attempt++) {
        const state = await runtime.control({ operation: "poll", flowID });
        assert.ok("busy" in state);
        if (!state.busy) return state;
        await new Promise((resolve) => setTimeout(resolve, 5));
      }
      throw new Error("Authorization did not settle");
    }
    const opened = await runtime.control({
      operation: "reauthorize",
      provider: "openai-codex",
      name: "X",
    });
    assert.ok("flowID" in opened);
    const result = await finish(opened.flowID);
    assert.equal(result.outcome, "success");
    assert.equal(store.readCodexAccountState().activeAccount, "Y");
    assert.equal(
      store.readCodexAccountState().accounts.find((row) => row.name === "X")
        ?.credential.access,
      "private-replaced",
    );
    const cancelledTerminal = await runtime.control({
      operation: "cancel",
      flowID: opened.flowID,
    });
    assert.ok("outcome" in cancelledTerminal);
    assert.equal(cancelledTerminal.outcome, "success");
    fail = true;
    const second = await runtime.control({
      operation: "login",
      provider: "openai-codex",
      name: "New",
    });
    assert.ok("flowID" in second);
    const failure = await finish(second.flowID);
    assert.equal(failure.outcome, "failed");
    assert.equal(store.readCodexAccountState().accounts.length, 2);
    assert.doesNotMatch(
      JSON.stringify(failure),
      /private-secret|private-refresh|private-replaced/u,
    );
    await assert.rejects(
      runtime.control({
        operation: "reauthorize",
        provider: "openai-codex",
        name: "Missing",
      }),
    );
  } finally {
    await runtime.close();
    execFileSync("trash", [directory]);
  }
});
