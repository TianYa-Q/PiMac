import assert from "node:assert/strict";
import { test } from "node:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createJiti } from "jiti";

const root = await mkdtemp(join(tmpdir(), "store-keys-"));
process.env.PI_CODING_AGENT_DIR = root;
const jiti = createJiti(import.meta.url);
const { createAccountStore } = await jiti.import("../store.ts");
const credential = {
  type: "oauth",
  access: "synthetic",
  refresh: "synthetic",
  expires: 2000000000000,
};

test("prototype-like names survive creation, refresh, selection and removal", async () => {
  try {
    const store = createAccountStore();
    // __proto__ must also work as the FIRST write, before a document exists.
    for (const name of ["__proto__", "constructor", "toString", "normal"])
      await store.saveAccount(name, credential);
    assert.equal(store.readCodexAccountState().accounts.length, 4);
    for (const name of ["__proto__", "constructor", "toString"]) {
      await store.setActiveAccount(name);
      assert.equal(store.readCodexAccountState().activeAccount, name);
      await store.refreshStoredCredential(name, async (old) => ({
        ...old,
        access: "refreshed",
      }));
      assert.equal(
        store.readCodexAccountState().accounts.find((a) => a.name === name)
          .credential.access,
        "refreshed",
      );
    }
    await store.setActiveAccount("normal");
    for (const name of ["__proto__", "constructor", "toString"])
      await store.removeAccount(name);
    assert.deepEqual(
      store.readCodexAccountState().accounts.map((a) => a.name),
      ["normal"],
    );
    await assert.rejects(
      store.refreshStoredCredential("constructor", async () => credential),
      /不存在/u,
    );

    for (const name of ["__proto__", "constructor", "toString"]) {
      const now = Date.now();
      assert.equal(
        await store.claimAutoWarmupWindow(name, now + 100000, now, 60000),
        true,
      );
      assert.equal(
        await store.claimAutoWarmupWindow(name, now + 100000, now, 60000),
        false,
      );
    }
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
