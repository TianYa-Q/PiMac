// Real installed Pi RPC + codemode test; synthetic provider, no remote calls or user settings.
// Run: node scripts/test-pi-compatibility.mjs (optionally PI_PATH=/path/to/pi)
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, writeFile, mkdir, rm } from "node:fs/promises";
import { enableCodemode } from "./enable-codemode.mjs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = await mkdtemp(join(tmpdir(), "pimac-compat-"));
const extension = join(root, "handled.ts");
const agentDir = join(root, "agent");
await mkdir(agentDir);
await writeFile(join(agentDir, "settings.json"), JSON.stringify(enableCodemode({})));
await writeFile(join(root, "fixture.txt"), "codemode fixture");
await writeFile(extension, `export default function(pi) {
  pi.registerCommand("compat-handled", { handler: async () => {} });
  pi.on("input", event => event.text === "compat-consume" ? { action: "handled" } : undefined);
  pi.on("session_start", (_event, ctx) => ctx.ui.setStatus("compat-tools", JSON.stringify(pi.getActiveTools())));
}`);
const offlineProvider = fileURLToPath(new URL("./fixtures/pi-codemode.ts", import.meta.url));
const fast = fileURLToPath(new URL("../Sources/PiMacApp/Resources/pimac-fast.ts", import.meta.url));
const accounts = fileURLToPath(new URL("../extensions/account-usage/index.ts", import.meta.url));
const child = spawn(process.env.PI_PATH || "pi", [
  "--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates",
  "-e", "builtin:codemode", "-e", fast, "-e", extension, "-e", accounts, "-e", offlineProvider,
  "--provider", "openai", "--model", "gpt-6.1-sol", "--api-key", "sk-pimac-test-not-a-real-key",
], {
  cwd: root,
  env: { ...process.env, PI_CODING_AGENT_DIR: agentDir, PI_OFFLINE: "1",
    PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0", PIMAC_FAST_MODE: "0" },
  stdio: ["pipe", "pipe", "pipe"],
});
let buffer = "";
let stderr = "";
let counter = 0;
const pending = new Map();
const events = [];
let failure;
function rejectAll(error) {
  failure = error;
  for (const { reject, timer } of pending.values()) { clearTimeout(timer); reject(error); }
  pending.clear();
}
child.stderr.setEncoding("utf8");
child.stderr.on("data", text => { stderr += text; });
child.stdout.setEncoding("utf8");
child.stdout.on("data", text => {
  buffer += text;
  let newline;
  while ((newline = buffer.indexOf("\n")) >= 0) {
    const line = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    try {
      const event = JSON.parse(line);
      events.push(event);
      const request = event.type === "response" && pending.get(event.id);
      if (request) {
        pending.delete(event.id);
        clearTimeout(request.timer);
        request.resolve(event);
      }
    } catch (error) { rejectAll(error); }
  }
});
child.on("error", rejectAll);
child.stdin.on("error", rejectAll);
const closed = new Promise(resolve => child.on("close", (code, signal) => {
  rejectAll(new Error(`Pi exited: ${code}/${signal}. ${stderr}`));
  resolve();
}));
function send(command) {
  if (failure) return Promise.reject(failure);
  const id = String(++counter);
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timeout: ${command.type}. ${stderr}`)); }, 15000);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(JSON.stringify({ ...command, id }) + "\n");
  });
}
try {
  assert.equal((await send({ type: "get_state" })).success, true);
  const commands = await send({ type: "get_commands" });
  assert.equal(commands.success, true);
  assert(commands.data.commands.some(command => command.name === "pimac-fast"));
  for (const message of ["/pimac-fast on", "/compat-handled", "compat-consume", "/pimac-fast off"]) {
    const response = await send({ type: "prompt", message });
    assert.equal(response.success, true, JSON.stringify(response));
    assert.equal(response.data.disposition, "handled");
  }
  for (const type of ["steer", "follow_up"]) {
    const response = await send({ type, message: "compat-consume" });
    assert.equal(response.success, true, JSON.stringify(response));
    assert.equal(response.data.disposition, "handled");
  }
  assert.equal(events.filter(event => event.type === "agent_start").length, 0);
  const active = JSON.parse(events.find(event => event.statusKey === "compat-tools").statusText);
  for (const tool of ["read", "bash", "edit", "write", "codemode"]) assert(active.includes(tool));
  assert.equal((await send({ type: "set_model", provider: "pimac-compat", modelId: "offline" })).success, true);
  const codemodeResponse = await send({ type: "prompt", message: "Run the offline codemode compatibility sequence" });
  assert.equal(codemodeResponse.success, true, JSON.stringify(codemodeResponse));
  assert.equal(codemodeResponse.data.disposition, "started");
  const deadline = Date.now() + 15000;
  while (!events.some(event => event.type === "agent_settled")) {
    if (failure) throw failure;
    if (Date.now() >= deadline) throw new Error(`Codemode run did not settle: ${stderr}`);
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  const history = await send({ type: "get_messages" });
  const results = history.data.messages.filter(message => message.role === "toolResult" && message.toolName === "codemode");
  assert.equal(results.length, 3, JSON.stringify(history));
  const [result, stored, scriptError] = results;
  assert.equal(result.isError, false, JSON.stringify(result));
  assert(result.content.some(block => block.type === "text" && block.text.includes("codemode fixture")));
  assert(result.content.some(block => block.type === "text" && block.text.includes("codemode-shell")));
  assert(result.content.some(block => block.type === "image" && block.mimeType === "image/png"));
  assert(stored.content.some(block => block.type === "text" && block.text.includes("42")));
  assert.equal(scriptError.isError, true);
  assert(scriptError.content.some(block => block.type === "text" && block.text.includes("compat-script-error")));
  assert(events.some(event => event.type === "tool_execution_end" && event.toolName === "read" && event.parentToolCallId));
  assert(events.some(event => event.type === "tool_execution_end" && event.toolName === "bash" && event.parentToolCallId));
  assert.equal(result.nestedCalls.calls.length, 2);
  assert.equal(result.nestedCalls.complete, true);
  assert.equal(result.usage.totalTokens, 9);
  assert.equal(result.usage.cost.total, 0.03);
  const stats = await send({ type: "get_session_stats" });
  assert.equal(stats.success, true);
  assert.equal(stats.data.cost, 0.03);
  assert.equal(events.filter(event => event.type === "extension_error").length, 0);
  const quota = events.filter(event => event.statusKey === "account-usage-gui" && event.statusText).map(event => JSON.parse(event.statusText)).find(snapshot => snapshot.provider === "openai");
  assert.equal(quota.version, 2);
  assert.equal(quota.provider, "openai");
  assert.equal(quota.managesSelectedAuth, false);
  assert.equal(quota.supportsAccountSwitch, true);
  assert.deepEqual(events.filter(event => event.statusKey === "pimac-fast").map(event => event.statusText), ["off", "on", "off"]);
  const abortStart = events.length;
  assert.equal((await send({ type: "prompt", message: "compat-abort" })).data.disposition, "started");
  const abortDeadline = Date.now() + 10000;
  while (!events.slice(abortStart).some(event => event.type === "tool_execution_start" && event.toolName === "bash")) {
    if (failure) throw failure;
    if (Date.now() >= abortDeadline) throw new Error("Abort test did not reach nested bash");
    await new Promise(resolve => setTimeout(resolve, 20));
  }
  assert.equal((await send({ type: "abort" })).success, true);
  assert.equal((await send({ type: "get_state" })).data.isStreaming, false);
  assert(events.slice(abortStart).some(event => event.type === "agent_settled"));
  console.log("Installed Pi RPC + codemode compatibility tests passed (real sandbox, no remote model requests).");
} finally {
  child.stdin.end();
  const timer = setTimeout(() => child.kill("SIGKILL"), 3000);
  await closed;
  clearTimeout(timer);
  await rm(root, { recursive: true, force: true });
}
