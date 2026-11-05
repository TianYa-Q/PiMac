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

test("session reconnects never prompt for Goal focus or resume, and paused conversations stay quiet", async () => {
  const source = await readFile(new URL("fixtures/pi-goal-events-0.32.3.txt", import.meta.url), "utf8");
  const patched = bridgeGoalSource("goal-events.ts", source);
  assert.equal(bridgeGoalSource("goal-events.ts", patched), patched, "installation is idempotent");
  const oldBridge = goalBridgePatches.find((patch) => patch.file === "goal-events.ts")!;
  assert.equal(bridgeGoalSource("goal-events.ts", source.replace(oldBridge.anchor, oldBridge.replacement)), patched,
    "existing presentation-only installations can upgrade without reinstalling");
  const previousBridge = goalBridgePatches.filter((patch) => patch.file === "goal-events.ts").slice(0, -1)
    .reduce((text, patch) => text.replace(patch.anchor, patch.replacement), source);
  assert.equal(bridgeGoalSource("goal-events.ts", previousBridge), patched,
    "existing paused-conversation installations can upgrade without losing their patches");
  assert.throws(() => bridgeGoalSource("goal-events.ts", patched + "\n// local edit"), /differs from pinned/);

  // 从经完整原文哈希校验的真实事件实现提取两个入口；不复制分支逻辑，也不调用模型。
  const ast = ts.createSourceFile("goal-events.ts", patched, ts.ScriptTarget.Latest, true);
  let sessionStart = "";
  let contextParts = "";
  function visit(node: ts.Node): void {
    if (ts.isCallExpression(node) && node.expression.getText(ast) === "pi.on" &&
        node.arguments[0]?.getText(ast) === '"session_start"') {
      sessionStart = node.arguments[1]!.getText(ast);
    }
    if (ts.isFunctionDeclaration(node) && node.name?.text === "currentGoalContextParts") {
      contextParts = node.getText(ast);
    }
    ts.forEachChild(node, visit);
  }
  visit(ast);
  assert(sessionStart && contextParts);
  const compiled = ts.transpileModule(`${contextParts}\nreturn { start: ${sessionStart}, parts: currentGoalContextParts };`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None },
  }).outputText;
  const noop = () => {};
  let reports = 0;
  let restores = 0;
  let checkpoint: string | null = null;
  const paused = { id: "paused-goal", objective: "Export CSV", status: "paused", stopReason: "user" };
  const core = {
    state: { goal: paused as typeof paused | null }, auditMessages: new Map(),
    hasExplicitSessionFocus: false,
    goalsById: new Map([[paused.id, paused], ["other-goal", { ...paused, id: "other-goal", status: "active" }]]),
    openGoals: () => assert.fail("reconnection must not open the goal selector"),
    setFocusedGoalId: () => assert.fail("reconnection must not choose a goal"),
    armFocusedContinuation: () => assert.fail("reconnection must not arm a new continuation"),
    goalService: { flushTurn: noop }, loadState: async () => {},
    updateUI: () => { reports++; }, installGoalToolProfile: noop,
    beginAccounting: noop,
    runtime: { getCheckpointGoalId: () => checkpoint },
    isActionableContinuationGoal: () => false,
    scheduler: { restore: () => { restores++; }, resume: () => assert.fail("must not resume implicitly") },
  };
  const dependencies = {
    core, invalidateGoalSettingsCache: noop, invalidateGoalPoolCache: noop,
    invalidateGoalLedgerCache: noop, loadGoalSettings: () => ({}),
    rehydrateDraft: noop, syncTerminalInputPause: noop,
    goalRuntimeEvents: () => [], latestAuditorResultForGoal: () => null,
    untrustedObjectiveBlock: (goal: typeof paused) => goal.objective,
    staleContinuationPrompt: () => "STALE CHECKPOINT: do not continue",
    otherOpenGoalCount: (goals: Map<string, unknown>) => goals.size,
  };
  const hooks = new Function(...Object.keys(dependencies), compiled)(...Object.values(dependencies));
  const ctx = { hasUI: true, cwd: "/isolated", ui: {
    confirm: () => assert.fail("must not ask to resume"),
    select: () => assert.fail("must not ask to select a goal"),
  } };
  for (let i = 0; i < 3; i++) {
    await hooks.start({ reason: "resume" }, ctx);
    const parts = hooks.parts(ctx);
    assert.match(parts.state, /PI GOAL PAUSED goalId=paused-goal/);
    assert.match(parts.state, /Handle the user's current message normally/);
    assert.match(parts.state, /Do not ask, remind, or suggest/);
    assert.match(parts.state, /not consent to resume/);
    assert.match(parts.state, /do not autonomously continue its work/);
    assert.equal(core.state.goal?.status, "paused");
  }
  assert.equal(reports, 3, "reconnections still publish authoritative goal status");
  assert.equal(restores, 3, "upstream scheduler restoration remains intact");
  checkpoint = "paused-goal";
  assert.match(hooks.parts(ctx).state, /STALE CHECKPOINT/, "stale continuation guard precedes quiet paused context");

  checkpoint = null;
  core.state.goal = null;
  const goalsBefore = [...core.goalsById.entries()];
  // 复现截图：工作区有暂停和运行中的两个目标，但此会话未绑定目标。
  for (const reason of ["resume", "resume", "resume", "startup"]) {
    await hooks.start({ reason }, ctx);
    assert.equal(core.state.goal, null, "ordinary session opening must stay unfocused");
    assert.deepEqual([...core.goalsById.entries()], goalsBefore, "other goals must remain untouched");
  }
  assert.equal(reports, 7, "unfocused reconnects still publish the empty goal snapshot");
  assert.equal(restores, 7, "removing the picker does not skip scheduler restoration");
});

test("installer refuses unknown or locally modified sources", () => {
  assert.throws(() => bridgeGoalSource("goal-state.ts", "locally modified"), /differs from pinned/);
  assert.throws(() => bridgeGoalSource("other.ts", ""), /Unknown Goal bridge file/);
});
