import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import ts from "typescript";

test("Pi unlimited RPC retry budget stays null in running and terminal Server projections", async () => {
  const patches = JSON.parse(await readFile(new URL("../patches.json", import.meta.url), "utf8"))[
    "packages/provider-pi/src/server/adapter.ts"
  ] as { oldText: string; newText: string }[];
  const patch = patches.find(({ oldText }) => oldText.includes("const maxAttempts = Math.max("))!;
  assert(patch);
  const upstream = await readFile(new URL("../upstream/packages/provider-pi/src/server/adapter.ts", import.meta.url), "utf8");
  assert.equal(upstream.split(patch.oldText).length, 2);
  const compiled = ts.transpileModule(`${patch.newText}\nreturn maxAttempts;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022 },
  }).outputText;
  const project = new Function("event", "attempt", "recordNumber", compiled);
  const number = (record: Record<string, unknown>, key: string) => typeof record[key] === "number" ? record[key] : undefined;
  assert.equal(project({ maxAttempts: null }, 7, number), null);
  assert.equal(project({ maxAttempts: 3 }, 1, number), 3);
  assert.equal(project({}, 7, number), 7, "old providers with missing budgets keep their existing fallback");
  const terminal = patches.find(({ oldText }) => oldText === "                maxAttempts: current?.retry.maxAttempts ?? attempt,")!;
  assert(terminal);
  const finish = new Function("current", "attempt", `return ({ ${terminal.newText} }).maxAttempts;`);
  assert.equal(finish({ retry: { maxAttempts: null } }, 7), null);
  assert.equal(finish({ retry: { maxAttempts: 3 } }, 3), 3);
  assert.equal(finish(null, 1), 1);
});
