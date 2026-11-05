import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import test from "node:test";
import ts from "typescript";
import { bridgeGoalSource } from "../../../scripts/install-pi-goal.ts";

const fixture = async (name: string): Promise<string> => readFile(
  new URL(`fixtures/pi-goal-${name}-0.32.3.txt`, import.meta.url), "utf8",
);
const compile = (source: string): string => ts.transpileModule(source, {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None },
}).outputText;

// 执行哈希校验后的上游分类器和真实生命周期入口，不复制恢复决策或启动模型。
async function recoveryCode(): Promise<{ classifier: string; hooks: string }> {
  const original = await fixture("format");
  const patched = bridgeGoalSource("goal-format.ts", original);
  assert.equal(bridgeGoalSource("goal-format.ts", patched), patched);
  assert.throws(() => bridgeGoalSource("goal-format.ts", `${patched}\n// unknown edit`), /differs from pinned/);
  const ast = ts.createSourceFile("goal-format.ts", patched, ts.ScriptTarget.Latest, true);
  const names = new Set(["isErrorAssistantMessage", "isAbortedAssistantMessage",
    "isNetworkErrorAssistantMessage", "hasErrorAssistantMessage", "hasAbortedAssistantMessage",
    "hasNetworkErrorAssistantMessage"]);
  const classifier = `const asRecord = value => value && typeof value === "object" ? value : null;\n` + ast.statements.filter((node) =>
    (ts.isFunctionDeclaration(node) && names.has(node.name?.text ?? "")) ||
    (ts.isVariableStatement(node) && node.declarationList.declarations.some((decl) =>
      ["TRANSIENT_PROVIDER_ERROR_RE", "NON_TRANSIENT_PROVIDER_ERROR_RE"].includes(decl.name.getText(ast)))),
  ).map((node) => node.getText(ast).replace(/^export /, "")).join("\n");
  const events = bridgeGoalSource("goal-events.ts", await fixture("events"));
  const eventAst = ts.createSourceFile("goal-events.ts", events, ts.ScriptTarget.Latest, true);
  const hooks: string[] = [];
  function visit(node: ts.Node): void {
    if (ts.isCallExpression(node) && node.expression.getText(eventAst) === "pi.on" &&
        ['"agent_end"', '"agent_settled"'].includes(node.arguments[0]?.getText(eventAst) ?? "")) {
      hooks.push(node.getText(eventAst));
    }
    ts.forEachChild(node, visit);
  }
  visit(eventAst);
  assert.equal(hooks.length, 2);
  return { classifier, hooks: hooks.join(";\n") };
}

const message = (errorMessage: string, stopReason = "error", role = "assistant") => ({
  role, stopReason, errorMessage,
});

test("Goal transport classification includes fetch failures without retrying quota or ordinary output", async () => {
  const { classifier } = await recoveryCode();
  const classify = new Function(compile(`${classifier}\nreturn isNetworkErrorAssistantMessage;`))();
  for (const text of ["fetch failed", "TypeError: fetch failed", "ECONNRESET", "connect ECONNREFUSED",
    "ETIMEDOUT", "getaddrinfo ENOTFOUND", "EAI_AGAIN", "socket hang up", "other side closed",
    "503 server_error", "429 rate limit"]) {
    assert.equal(classify(message(text)), true, text);
  }
  for (const text of ["401 Unauthorized", "403 Forbidden", "invalid API key", "400 invalid request",
    "401 Unauthorized fetch failed", "403 Forbidden 503", "invalid_api_key: fetch failed",
    "insufficient_quota fetch failed", "billing: fetch failed", "quota exceeded ECONNRESET", ""]) {
    assert.equal(classify(message(text)), false, text);
  }
  for (const stopReason of ["stop", "aborted", "toolUse"]) {
    assert.equal(classify(message("fetch failed", stopReason)), false);
  }
  assert.equal(classify(message("fetch failed", "error", "user")), false);
});

test("fetch failures reach upstream recovery only after settle; pause, abort and recovery caps stay authoritative", async () => {
  const { classifier, hooks } = await recoveryCode();
  const registered = new Map<string, (event: unknown, ctx: unknown) => Promise<void>>();
  let scheduled = 0;
  let paused = 0;
  let capReached = false;
  const goal = { id: "test-goal", status: "active", autoContinue: true };
  const noop = () => {};
  const core = {
    state: { goal }, runningGoalId: goal.id,
    runtime: {
      clearContinuationState: noop, clearNetworkErrorBackoff: noop,
      scheduleNetworkErrorRetry: (_ctx: unknown, current: unknown, policy: unknown) => {
        assert.equal(current, goal);
        assert.deepEqual(policy, { maxAttempts: 3, maxDelayMs: 60_000 });
        scheduled++;
        return capReached ? null : { attempt: 1, maxAttempts: 3, delayMs: 5_000 };
      },
    },
    auditMessages: { flush: noop }, scheduler: { settled: noop },
    persist: noop, updateUI: noop, accountProgress: noop,
    reconcileFocusedGoalFromDisk: () => true,
    pauseActiveGoal: () => { paused++; goal.status = "paused"; },
    isActionableContinuationGoal: (id: string) => id === goal.id && goal.status === "active",
  };
  const notify: string[] = [];
  const ctx = { cwd: "/isolated", signal: { aborted: false }, ui: {
    notify: (text: string) => { notify.push(text); },
  } };
  new Function("pi", "core", "loadGoalSettings", "assistantTurnTokens", compile(`
    ${classifier}
    let continuationAfterSettleFor = null;
    let networkErrorRecoveryAfterSettleFor = null;
    ${hooks}
  `))({ on: (name: string, handler: (event: unknown, ctx: unknown) => Promise<void>) => {
    registered.set(name, handler);
  } }, core, () => ({ networkRecovery: { maxAttempts: 3, maxDelayMs: 60_000 } }), () => 0);
  const end = async (text: string) => registered.get("agent_end")!({ messages: [message(text)] }, ctx);
  const settle = async () => registered.get("agent_settled")!({}, ctx);
  await end("fetch failed");
  assert.equal(scheduled, 0, "do not compete with Pi's in-flight retries");
  await settle();
  assert.equal(scheduled, 1);
  assert.match(notify.at(-1)!, /Retrying the goal/);
  await settle();
  assert.equal(scheduled, 1, "settle cannot schedule the same failure twice");

  capReached = true;
  await end("fetch failed"); await settle();
  assert.equal(scheduled, 2);
  assert.match(notify.at(-1)!, /after all recovery attempts/);
  for (const text of ["401 Unauthorized", "billing: fetch failed"]) {
    await end(text); await settle();
    assert.equal(scheduled, 2);
  }
  await end("fetch failed");
  await registered.get("agent_settled")!({ aborted: true }, ctx);
  assert.equal(paused, 1, "cancellation during Pi backoff arrives after agent_end");
  assert.equal(scheduled, 2, "final cancellation must not start a Goal recovery timer");
  goal.status = "active";
  ctx.signal.aborted = true;
  await end("fetch failed"); await settle();
  assert.equal(paused, 2);
  assert.equal(scheduled, 2, "user stop takes precedence over transport recovery");
  ctx.signal.aborted = false;
  await end("fetch failed"); await settle();
  assert.equal(scheduled, 2, "never resume an already paused goal");
});
