import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { resolve, join } from "node:path";
import { fileURLToPath } from "node:url";
import { goalStatus } from "../index.ts";
import { managedSettings, runtimeRoot } from "../../../scripts/manage-pi-runtime.ts";
const goalAdapter = fileURLToPath(new URL("../", import.meta.url));

test("single engine selection preserves unrelated settings and is idempotent", () => {
  const settings = { keep: 42, packages: ["npm:pi-web-access", "npm:pi-goal-x@0.32.3"] };
  const result = managedSettings(settings);
  assert.deepEqual(result.packages, [join(runtimeRoot, "node_modules/pi-antigravity"), join(runtimeRoot, "node_modules/pi-web-access"), goalAdapter.replace(/\/$/u, "")]);
  assert.equal(result.keep, 42);
  assert.deepEqual(managedSettings(result), result);
  assert.throws(() => managedSettings({ packages: "broken" }));
});

test("state bridge distinguishes clear from malformed state", () => {
  assert.deepEqual(goalStatus({ goal: null }), { version: 1, goal: null });
  const value = { text: "实现导出", status: "paused", tokensUsed: 12.9, timeUsedSeconds: 3.1 };
  assert.deepEqual(goalStatus({ goal: value }).goal, {
    objective: "实现导出", status: "paused", tokensUsed: 12, timeUsedSeconds: 3,
  });
  for (const goal of [undefined, {}, { ...value, tokensUsed: -1 }, { ...value, tokenBudget: "10" }, { ...value, status: "unknown" }]) {
    assert.throws(() => goalStatus({ goal }));
  }
});

test("real Pi RPC restores, pauses, edits and clears without confirmation or model calls", { timeout: 30000 }, async () => {
  const repository = fileURLToPath(new URL("../../../", import.meta.url));
  const parent = join(repository, "tmp/schovest-goal-switch");
  await mkdir(parent, { recursive: true });
  const work = await mkdtemp(join(parent, "rpc-"));
  const seed = join(work, "seed.ts");
  await writeFile(seed, `export default function(pi) {
    pi.on("session_start", (_event, ctx) => {
      if (ctx.sessionManager.getBranch().some(e => e.type === "custom" && e.customType === "goal-state")) return;
      const now = Date.now();
      pi.appendEntry("goal-state", { goal: { id: "isolated-goal", text: "原目标", status: "active",
        startedAt: now, updatedAt: now, iteration: 0, tokensUsed: 12, timeUsedSeconds: 3,
        baselineTokens: 0, activeStartedAt: now, automaticModelTurns: 0, toolFreeRepeatCount: 0 } });
    });
  }`);
  const cli = resolve(repository, "extensions/pi-goal/node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js");
  const child = spawn(process.execPath, [cli, "--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates",
    "-e", seed, "-e", join(goalAdapter, "index.ts")], {
    cwd: work, env: { ...process.env, PI_CODING_AGENT_DIR: join(work, "agent"), PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  type Event = Record<string, unknown>;
  const events: Event[] = [];
  let stderr = "", buffer = "", exited = false;
  child.stderr.setEncoding("utf8").on("data", text => { stderr += text; });
  child.stdout.setEncoding("utf8").on("data", text => {
    buffer += text;
    let end: number;
    while ((end = buffer.indexOf("\n")) >= 0) {
      events.push(JSON.parse(buffer.slice(0, end)) as Event); buffer = buffer.slice(end + 1);
    }
  });
  const closed = new Promise<void>(done => child.once("close", () => { exited = true; done(); }));
  const until = async (predicate: () => boolean) => {
    const deadline = Date.now() + 10000;
    while (!predicate()) {
      if (exited || Date.now() > deadline) throw new Error(`RPC failed: ${stderr}\n${JSON.stringify(events.slice(-5))}`);
      await new Promise(done => setTimeout(done, 10));
    }
  };
  let sequence = 0;
  const send = async (message: string) => {
    const id = String(++sequence);
    child.stdin.write(JSON.stringify({ id, type: "prompt", message }) + "\n");
    await until(() => events.some(event => event.type === "response" && event.id === id));
    assert.equal(events.find(event => event.type === "response" && event.id === id)?.success, true, stderr);
  };
  const latestGoal = () => {
    const event = events.findLast(event => event.statusKey === "pimac-goal");
    return event ? JSON.parse(String(event.statusText)).goal as Record<string, unknown> | null : undefined;
  };
  try {
    await until(() => latestGoal()?.status === "active");
    await send("/goal pause");
    await until(() => latestGoal()?.status === "paused");
    const tokensBeforeEdit = latestGoal()?.tokensUsed;
    await send("/goal edit 修改后的目标");
    await until(() => latestGoal()?.objective === "修改后的目标");
    assert.equal(latestGoal()?.status, "paused");
    assert.equal(latestGoal()?.tokensUsed, tokensBeforeEdit);
    await send("/goal clear");
    await until(() => latestGoal() === null);
    assert(!events.some(event => event.type === "extension_ui_request" && ["confirm", "select"].includes(String(event.method))));
    assert(!events.some(event => event.type === "agent_start"), "management must not invoke a model");
  } finally {
    child.stdin.end();
    if (!exited) child.kill("SIGTERM");
    await closed;
  }
});
