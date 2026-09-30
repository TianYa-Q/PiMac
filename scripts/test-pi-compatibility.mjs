// Real installed Pi RPC smoke test; no provider calls, credentials or user settings.
// Run: node scripts/test-pi-compatibility.mjs (optionally PI_PATH=/path/to/pi)
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = await mkdtemp(join(tmpdir(), "pimac-compat-"));
const extension = join(root, "handled.ts");
await writeFile(extension, `export default function(pi) {
  pi.registerCommand("compat-handled", { handler: async () => {} });
  pi.on("input", event => event.text === "compat-consume" ? { action: "handled" } : undefined);
}`);
const fast = fileURLToPath(new URL("../Sources/PiMacApp/Resources/pimac-fast.ts", import.meta.url));
const accounts = fileURLToPath(new URL("../extensions/account-usage/index.ts", import.meta.url));
const child = spawn(process.env.PI_PATH || "pi", [
  "--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates",
  "-e", fast, "-e", extension, "-e", accounts,
  "--provider", "openai", "--model", "gpt-6.1-sol", "--api-key", "sk-pimac-test-not-a-real-key",
], {
  cwd: root,
  env: { ...process.env, PI_CODING_AGENT_DIR: join(root, "agent"), PI_OFFLINE: "1",
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
  assert.equal(events.filter(event => event.type === "extension_error").length, 0);
  const quota = events.filter(event => event.statusKey === "account-usage-gui" && event.statusText).map(event => JSON.parse(event.statusText)).at(-1);
  assert.equal(quota.version, 2);
  assert.equal(quota.provider, "openai");
  assert.equal(quota.managesSelectedAuth, false);
  assert.equal(quota.supportsAccountSwitch, true);
  assert.deepEqual(events.filter(event => event.statusKey === "pimac-fast").map(event => event.statusText), ["off", "on", "off"]);
  console.log("Installed Pi RPC compatibility tests passed (no model requests).");
} finally {
  child.stdin.end();
  const timer = setTimeout(() => child.kill("SIGKILL"), 3000);
  await closed;
  clearTimeout(timer);
  await rm(root, { recursive: true, force: true });
}
