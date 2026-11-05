import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, realpath, writeFile } from "node:fs/promises";
import { findPackageJSON } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { installPiRetry, patchPiRetrySource, piRetryPatches } from "./install-pi-retry.ts";

const packageRoot = process.env.PI_RETRY_PACKAGE_ROOT;
assert(packageRoot, "Set PI_RETRY_PACKAGE_ROOT to the pinned Pi 1.3.0 package directory");
const root = await realpath(packageRoot);
const aiManifest = findPackageJSON("@earendil-works/pi-ai", pathToFileURL(join(root, "dist/index.js")).href);
assert(aiManifest, "Pi AI dependency must resolve");
const aiRoot = dirname(aiManifest);
for (const patch of piRetryPatches) {
  const path = join(patch.owner === "ai" ? aiRoot : root, patch.file);
  const source = await readFile(path, "utf8");
  assert.equal(patchPiRetrySource(source, patch), source, `installed ${patch.file}`);
  assert.throws(() => patchPiRetrySource(source + "\n// unknown edit", patch), /differs from pinned/);
}
const { SettingsManager } = await import(pathToFileURL(join(root, "dist/core/settings-manager.js")).href);
const retry = await import(pathToFileURL(join(aiRoot, "dist/utils/retry.js")).href);
const unlimited = SettingsManager.inMemory({ retry: { enabled: true, unlimited: true,
  maxRetries: 3, baseDelayMs: 0, maxAgentDelayMs: 0 } }).getRetrySettings();
assert.equal(unlimited.maxRetries, Infinity);
assert.equal(JSON.parse(JSON.stringify({ maxAttempts: unlimited.maxRetries })).maxAttempts, null);
for (const maxRetries of [0, 3]) {
  assert.equal(SettingsManager.inMemory({ retry: { unlimited: false, maxRetries } }).getRetrySettings().maxRetries, maxRetries);
}
assert.deepEqual([1, 2, 3, 4, 5, 6, 7, 1025].map((attempt) =>
  retry.retryDelayMs({ baseDelayMs: 2000, maxAgentDelayMs: 60_000 }, attempt)),
[2000, 4000, 8000, 16_000, 32_000, 60_000, 60_000, 60_000]);
const failure = (errorMessage: string) => ({ stopReason: "error", errorMessage });
for (const text of ["fetch failed", "ECONNRESET", "ETIMEDOUT", "503 server_error", "429 rate limit"]) {
  assert.equal(retry.isRetryableAssistantError(failure(text)), true, text);
}
for (const text of ["401 Unauthorized fetch failed", "403 Forbidden 503", "400 invalid request 500",
  "invalid_api_key: fetch failed", "insufficient_quota 429", "billing: fetch failed"]) {
  assert.equal(retry.isRetryableAssistantError(failure(text)), false, text);
}
let produced = 0;
const summarized = await retry.retryAssistantCall(async () => ++produced <= 7 ? failure("fetch failed") : { stopReason: "stop" }, unlimited);
assert.equal(summarized.stopReason, "stop");
assert.equal(produced, 8, "summary/compaction calls share the same persistent budget");
for (const policy of [{ ...unlimited, enabled: false }, { ...unlimited, maxRetries: 0 }, { ...unlimited, maxRetries: 2 }]) {
  produced = 0;
  await retry.retryAssistantCall(async () => { produced++; return failure("fetch failed"); }, policy);
  assert.equal(produced, policy.enabled ? policy.maxRetries + 1 : 1);
}
const controller = new AbortController();
produced = 0;
const cancelledSummary = await retry.retryAssistantCall(async () => { produced++; return failure("fetch failed"); },
  { ...unlimited, baseDelayMs: 60_000, maxAgentDelayMs: 60_000 }, controller.signal,
  { onRetryScheduled: () => controller.abort() });
assert.equal(cancelledSummary.stopReason, "aborted");
assert.equal(produced, 1, "cancelled 60-second summary backoff must not make another request");
console.log("SDK retry policy: infinite/finite/disabled, capped backoff, permanent errors, summaries and cancelled long backoff passed.");

await mkdir("tmp", { recursive: true });
const work = await mkdtemp(resolve("tmp/pi-retry-"));
await writeFile(join(work, ".keep"), "Pi persistent retry verification\n");
const agentDir = join(work, "agent");
await mkdir(agentDir);
await installPiRetry(root, agentDir, false);
await installPiRetry(root, agentDir, true);
// 使用短间隔测试真实重试循环；60 秒封顶已直接检查真实共享函数。
const settingsPath = join(agentDir, "settings.json");
const settings = JSON.parse(await readFile(settingsPath, "utf8"));
settings.retry.baseDelayMs = 1;
settings.retry.maxAgentDelayMs = 4;
await writeFile(settingsPath, JSON.stringify(settings));
const fixture = fileURLToPath(new URL("./fixtures/pi-retry.ts", import.meta.url));
const goalRoot = process.env.PI_RETRY_GOAL_ROOT;
assert(goalRoot, "Set PI_RETRY_GOAL_ROOT to the installed pi-goal-x@0.32.3 directory");
const wrapper = join(work, "retry-goal-wrapper.ts");
await writeFile(wrapper, `
import goalExtension from ${JSON.stringify(join(goalRoot, "extensions/goal.ts"))};
import retryFixture from ${JSON.stringify(fixture)};
export default function(pi) {
  goalExtension(pi);
  retryFixture(pi);
  pi.registerCommand("retry-test-goal", { handler: async (_args, ctx) => {
    pi._goalCore.replaceGoal({ objective: "Offline retry lifecycle verification", autoContinue: true, sisyphus: false }, ctx, false);
    pi._goalCore.updateUI(ctx);
  } });
}
`);
const child = spawn(process.execPath, [join(root, "dist/bundle/cli.js"), "--mode", "rpc", "--no-session",
  "--no-extensions", "--no-skills", "--no-prompt-templates", "-e", wrapper,
  "--provider", "pimac-retry-test", "--model", "offline"], {
  cwd: work, env: { ...process.env, PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1",
    PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" }, stdio: ["pipe", "pipe", "pipe"],
});
type Event = { type: string; id?: string; [key: string]: any };
const events: Event[] = [];
let buffer = "";
let stderr = "";
let exited = false;
child.stderr.setEncoding("utf8");
child.stderr.on("data", (chunk: string) => { stderr += chunk; });
child.stdout.setEncoding("utf8");
child.stdout.on("data", (chunk: string) => {
  buffer += chunk;
  let end: number;
  while ((end = buffer.indexOf("\n")) !== -1) {
    events.push(JSON.parse(buffer.slice(0, end)));
    buffer = buffer.slice(end + 1);
  }
});
const closed = new Promise<void>((resolve) => child.once("close", () => { exited = true; resolve(); }));
child.once("error", (error) => { stderr += String(error); });
async function until(predicate: () => boolean, timeout = 15_000): Promise<void> {
  const deadline = Date.now() + timeout;
  while (!predicate()) {
    if (exited || Date.now() > deadline) throw new Error(`Pi RPC wait failed: ${stderr}\n${JSON.stringify(events.slice(-5))}`);
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
}
let sequence = 0;
async function send(command: Record<string, unknown>): Promise<Event> {
  const id = String(++sequence);
  child.stdin.write(JSON.stringify({ ...command, id }) + "\n");
  await until(() => events.some((event) => event.type === "response" && event.id === id));
  const response = events.find((event) => event.type === "response" && event.id === id)!;
  assert.equal(response.success, true, JSON.stringify(response));
  return response;
}
try {
  await send({ type: "get_state" });
  let start = events.length;
  await send({ type: "prompt", message: "recover" });
  await until(() => events.slice(start).some((event) => event.type === "agent_settled"));
  const recovered = events.slice(start);
  const retries = recovered.filter((event) => event.type === "auto_retry_start");
  assert.equal(retries.length, 7, "not limited to the old three attempts");
  assert(retries.every((event) => event.maxAttempts === null));
  assert(recovered.filter((event) => event.type === "agent_end").slice(0, -1).every((event) => event.willRetry === true));
  assert(recovered.some((event) => event.type === "auto_retry_end" && event.success === true && event.attempt === 7));
  assert.equal(await readFile(join(work, "retry-tool-count.txt"), "utf8"), "x", "completed tool side effects are never replayed");
  const history = await send({ type: "get_messages" });
  const final = history.data.messages.filter((entry: Event) => entry.role === "assistant" && entry.stopReason === "stop").at(-1);
  assert.deepEqual(JSON.parse(final.content[0].text), { calls: 9, failedInContext: 0, toolResults: 1 });

  for (const text of ["401 Unauthorized fetch failed", "400 invalid request 503", "insufficient_quota 429"]) {
    start = events.length;
    await send({ type: "prompt", message: text });
    await until(() => events.slice(start).some((event) => event.type === "agent_settled"));
    assert(!events.slice(start).some((event) => event.type === "auto_retry_start"), text);
  }
  await send({ type: "prompt", message: "/retry-test-goal" });
  await until(() => events.some((event) => event.statusKey === "pimac-goal" && JSON.parse(event.statusText).goal?.status === "active"));
  start = events.length;
  await send({ type: "prompt", message: "forever" });
  await until(() => events.slice(start).filter((event) => event.type === "auto_retry_start").length >= 5);
  assert(!events.slice(start).some((event) => event.type === "agent_settled"));
  assert(!events.slice(start).some((event) => event.statusKey === "pimac-goal" && JSON.parse(event.statusText).goal?.status === "paused"),
    "Pi retrying must not pause the active Goal");
  assert(!events.slice(start).some((event) => /Retrying the goal/.test(event.message ?? "")),
    "Goal must not start a second recovery loop during Pi retries");
  const stoppedAt = Date.now();
  await send({ type: "abort" });
  await until(() => events.slice(start).some((event) => event.type === "agent_settled"));
  assert(Date.now() - stoppedAt < 1000, "stop must interrupt backoff immediately");
  assert.equal((await send({ type: "get_state" })).data.isStreaming, false);
  await until(() => events.slice(start).some((event) => event.statusKey === "pimac-goal" && JSON.parse(event.statusText).goal?.status === "paused"));
  const stoppedCount = events.filter((event) => event.type === "auto_retry_start").length;
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.equal(events.filter((event) => event.type === "auto_retry_start").length, stoppedCount);
  assert(!events.some((event) => event.type === "extension_error"), stderr);
  console.log("Real bundled Pi RPC + Goal: >3 failures recover, no tool replay, clean model context, permanent failures terminate, Goal stays active during retry and pauses on immediate abort passed.");
} finally {
  child.stdin.end();
  const timeout = setTimeout(() => child.kill("SIGKILL"), 3000);
  await closed;
  clearTimeout(timeout);
  // 只处理本测试的保留标记；验证产物按项目正常保留期管理。
  const trash = spawn("trash", [join(work, ".keep")], { stdio: "inherit" });
  await new Promise((resolve) => trash.once("close", resolve));
}
console.log(`Verification artifacts: ${work}`);
