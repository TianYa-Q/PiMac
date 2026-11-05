import assert from "node:assert/strict";
import test from "node:test";
import { readFile } from "node:fs/promises";
import * as Effect from "effect/Effect";
import ts from "typescript";
import { parsePiGoalStatus } from "../pi-goal-status.ts";

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

test("blocker reasons survive reports, normalize whitespace, and reject corrupt data", () => {
  assert.equal(parsePiGoalStatus(payload({ ...goal, status: "blocked", pauseReason: "  Need a real sample  " }))?.pauseReason,
    "Need a real sample");
  for (const pauseReason of [undefined, null, "", "   "]) {
    assert.equal(parsePiGoalStatus(payload({ ...goal, pauseReason }))?.pauseReason, undefined);
  }
  for (const pauseReason of [false, 12, [], {}]) {
    assert.throws(() => parsePiGoalStatus(payload({ ...goal, pauseReason })));
  }
});

test("corrupt or unsupported reports are errors, not empty goals", () => {
  for (const value of [undefined, "", "null", "[]", "{}", '{"version":2,"goal":null}',
    payload({ ...goal, objective: " " }), payload({ ...goal, status: "done" }),
    payload({ ...goal, tokensUsed: -1 }), payload({ ...goal, tokensUsed: true }),
    payload({ ...goal, timeUsedSeconds: 0.5 }), payload({ ...goal, tokenBudget: "100" }),
    payload({ ...goal, tokensUsed: Number.MAX_SAFE_INTEGER + 1 }),
  ]) assert.throws(() => parsePiGoalStatus(value));
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
  await send(payload({ ...goal, status: "blocked", pauseReason: "Need a real sample" }));
  assert.equal(state.providerThread.goal.pauseReason, "Need a real sample");
  await send(payload({ ...goal, status: "paused" }));
  assert.equal(state.providerThread.goal.pauseReason, undefined, "new state must clear obsolete reasons");
  assert.equal(state.providerThread.goal.status, "paused");
  await send("broken");
  assert.equal(errors.length, 1);
  assert.equal(state.providerThread.goal.status, "paused", "corruption must retain last known state");
  await send(payload(null));
  assert.equal(state.providerThread.goal, null);
  assert.equal(updates.length, 3);
  await send(payload(goal));
  adapter.reset();
  const second = adapter.register({ id: "second" });
  assert.equal(second.providerThread.goal, undefined, "native-session switches must not inherit cached goals");
});
