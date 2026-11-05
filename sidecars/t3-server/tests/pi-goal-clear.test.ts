import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import ts from "typescript";
import { bridgeGoalSource } from "../../../scripts/install-pi-goal.ts";

test("RPC clear archives the focused goal without dialogs; empty focus and stale goals stay safe", async () => {
  const original = await readFile(new URL("fixtures/pi-goal-commands-0.32.3.txt", import.meta.url), "utf8");
  const patched = bridgeGoalSource("goal-commands.ts", original);
  assert.equal(bridgeGoalSource("goal-commands.ts", patched), patched);
  assert.throws(() => bridgeGoalSource("goal-commands.ts", patched + "\n// local edit"), /differs from pinned/);
  const ast = ts.createSourceFile("goal-commands.ts", patched, ts.ScriptTarget.Latest, true);
  let source = "";
  function visit(node: ts.Node): void {
    if (ts.isFunctionDeclaration(node) && node.name?.text === "handleGoalClear") source = node.getText(ast);
    ts.forEachChild(node, visit);
  }
  visit(ast);
  assert(source);
  // 执行经完整哈希核对的扩展入口，不另写清除状态机；磁盘归档仍由扩展原实现负责。
  const compiled = ts.transpileModule(`${source}\nreturn handleGoalClear;`, {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None },
  }).outputText;
  for (const scenario of ["focused", "empty", "stale", "tui-cancel", "tui-confirm", "headless"]) {
    const goal = { id: "focused-goal", objective: "保留归档历史" };
    const state: { goal: typeof goal | null } = { goal: scenario === "empty" ? null : goal };
    const archived: string[] = [];
    let reconciles = 0;
    let confirms = 0;
    const core = {
      state, goalsById: new Map([["other", { id: "other" }]]),
      reconcileFocusedGoalFromDisk: () => { reconciles++; },
      focusedOperationToken: (id: string) => id,
      isFocusedOperationCurrent: (token: string) => scenario !== "stale" && token === goal.id,
      archiveCurrentGoal: (_ctx: unknown, reason: string) => {
        assert.equal(reason, "user"); archived.push(state.goal!.id); return goal;
      },
      setGoal: (value: null, _ctx: unknown, persist: boolean, reason: string) => {
        assert.equal(persist, true); assert.equal(reason, "cleared"); state.goal = value;
      },
    };
    const clear = new Function("core", "otherOpenGoalCount", "chooseOpenGoal", "clearGoalCommandMessage", "oneLineSummary", compiled)(
      core, () => 1, () => assert.fail("must not pick or clear another open goal"),
      ({ archived }: { archived: boolean }) => archived ? "archived" : "no focused goal", () => goal.objective,
    );
    const tui = scenario.startsWith("tui-");
    await clear({ mode: tui ? "interactive" : scenario === "headless" ? "print" : "rpc", hasUI: tui, ui: {
      notify: () => {},
      confirm: async () => { assert(tui, "RPC clear must never confirm"); confirms++; return scenario === "tui-confirm"; },
    } });
    const cleared = scenario === "focused" || scenario === "tui-confirm";
    assert.deepEqual(archived, cleared ? [goal.id] : []);
    assert.equal(state.goal, cleared || scenario === "empty" ? null : goal);
    assert.equal(core.goalsById.size, 1, "unrelated open goals stay untouched");
    assert.equal(confirms, tui ? 1 : 0);
    if (cleared) assert.equal(reconciles, 2, "retain the upstream final focus reconciliation");
  }
});
