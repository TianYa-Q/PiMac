import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import * as Effect from "effect/Effect";
import ts from "typescript";
import { parsePiGoalStatus } from "../pi-goal-status.ts";
import { bridgeGoalSource, goalBridgePatches } from "../../../scripts/install-pi-goal.ts";

const goal = { objective: "  Export CSV  ", status: "active", tokensUsed: 12, timeUsedSeconds: 3 };
const payload = (value: unknown): string => JSON.stringify({ version: 1, goal: value });

test("Goal bridge accepts lifecycle reports and explicit empty state, never infers completion", () => {
  assert.equal(parsePiGoalStatus(payload(null)), null);
  for (const status of ["active", "paused", "blocked", "budget_limited", "complete"]) {
    assert.deepEqual(parsePiGoalStatus(payload({ ...goal, status })), {
      ...goal, objective: "Export CSV", status,
    });
  }
  assert.equal(parsePiGoalStatus(payload({ ...goal, tokenBudget: null }))?.tokenBudget, null);
  assert.equal(parsePiGoalStatus(payload({ ...goal, tokenBudget: 100 }))?.tokenBudget, 100);
});

test("corrupt or unsupported reports are errors, not empty goals", () => {
  for (const value of [undefined, "", "null", "[]", "{}", '{"version":2,"goal":null}',
    payload({ ...goal, objective: " " }), payload({ ...goal, status: "done" }),
    payload({ ...goal, tokensUsed: -1 }), payload({ ...goal, tokensUsed: true }),
    payload({ ...goal, timeUsedSeconds: 0.5 }), payload({ ...goal, tokenBudget: "100" }),
    payload({ ...goal, tokensUsed: Number.MAX_SAFE_INTEGER + 1 }),
  ]) assert.throws(() => parsePiGoalStatus(value));
});

test("installed UI bridge publishes live state, deduplicates within a session, and clears across sessions", () => {
  const patch = goalBridgePatches.find((patch) => patch.file === "goal-state.ts")!;
  // 执行真正安装的桥接片段，而不是仅匹配补丁字符串；不加载审计器或调用模型。
  const compiled = ts.transpileModule(`${patch.replacement}\n}\nreturn updateUI;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None },
  }).outputText;
  const state: { goal: unknown } = { goal: null };
  const update = new Function("state", compiled)(state);
  let session = "first";
  const reports: unknown[] = [];
  const ctx = {
    mode: "rpc", hasUI: false,
    sessionManager: { getSessionId: () => session },
    ui: { setStatus: (key: string, value: string) => {
      assert.equal(key, "pimac-goal"); reports.push(parsePiGoalStatus(value));
    } },
  };
  update(ctx); update(ctx);
  assert.deepEqual(reports, [null]);
  state.goal = { ...goal, usage: { tokensUsed: 12.9, activeSeconds: 3.2 } };
  update(ctx); update(ctx);
  assert.deepEqual(reports.at(-1), { ...goal, objective: "Export CSV", tokensUsed: 12, timeUsedSeconds: 3 });
  assert.equal(reports.length, 2);
  state.goal = null;
  update(ctx);
  session = "second";
  update(ctx);
  assert.deepEqual(reports.slice(-2), [null, null]);
  update({ ...ctx, mode: "tui" });
  assert.equal(reports.length, 4);
});

test("adapter caches early reports, projects updates, clears switches, and reports corruption without killing work", async () => {
  const patches = JSON.parse(await readFile(new URL("../patches.json", import.meta.url), "utf8"))[
    "packages/provider-pi/src/server/adapter.ts"
  ] as { oldText: string; newText: string }[];
  const source = (anchor: string): string => {
    const patch = patches.find((patch) => patch.oldText === anchor);
    assert(patch, anchor);
    return patch.newText;
  };
  const code = [
    source("      let fastStatus: string | undefined;"),
    "let threadState = null; let appliedModel = null;",
    "const handle = event => Effect.gen(function* () {",
    source('        const method = recordString(event, "method");'),
    "});",
    "const register = providerThread => {",
    source("        threadState = { providerThread, activeTurn: null };"),
    "return threadState; };",
    "const adopt = (state, turnInput) => {",
    source("              state.providerThread = turnInput.providerThread;"),
    "};",
    "const reset = () => {",
    source("          threadState = null;\n          appliedModel = null;"),
    "}; return { handle, register, adopt, reset };",
  ].join("\n");
  const compiled = ts.transpileModule(code, { compilerOptions: { target: ts.ScriptTarget.ES2022 } }).outputText;
  const errors: unknown[] = [];
  const updates: unknown[] = [];
  const adapter = new Function("Effect", "parsePiGoalStatus", "recordString", "updateProviderThread", "emitExtensionError", compiled)(
    Effect, parsePiGoalStatus,
    (record: Record<string, unknown>, key: string) => typeof record[key] === "string" ? record[key] : undefined,
    (state: { providerThread: object }, patch: object) => Effect.sync(() => {
      Object.assign(state.providerThread, patch); updates.push(patch);
    }),
    (error: unknown) => Effect.sync(() => { errors.push(error); }),
  );
  const send = (text: unknown) => Effect.runPromise(adapter.handle({
    method: "setStatus", statusKey: "pimac-goal", statusText: text,
  }));
  await send(payload(goal)); // Pi can report before the app thread has been registered.
  const state = adapter.register({ id: "first" });
  assert.equal(state.providerThread.goal.status, "active");
  adapter.adopt(state, { providerThread: { id: "first", goal: null } });
  assert.equal(state.providerThread.goal.status, "active", "stale turn input must not erase the native report");
  await send(payload({ ...goal, status: "paused" }));
  assert.equal(state.providerThread.goal.status, "paused");
  await send("broken");
  assert.equal(errors.length, 1);
  assert.equal(state.providerThread.goal.status, "paused", "corruption must retain last known state");
  await send(payload(null));
  assert.equal(state.providerThread.goal, null);
  assert.equal(updates.length, 2);
  await send(payload(goal));
  adapter.reset();
  const second = adapter.register({ id: "second" });
  assert.equal(second.providerThread.goal, undefined, "native-session switches must not inherit cached goals");
});

test("installer refuses unknown or locally modified sources", () => {
  assert.throws(() => bridgeGoalSource("goal-state.ts", "locally modified"), /differs from pinned/);
  assert.throws(() => bridgeGoalSource("other.ts", ""), /Unknown Goal bridge file/);
});
