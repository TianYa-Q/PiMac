// Run with: node scripts/test-fast-extension.mjs (after companion npm ci)
import assert from "node:assert/strict";
import { createRequire } from "node:module";
const require = createRequire(new URL("../extensions/account-usage/package.json", import.meta.url));
const { createJiti } = require("jiti");
const factory = await createJiti(import.meta.url).import("../Sources/PiMacApp/Resources/pimac-fast.ts", { default: true });

function setup(initial) {
  process.env.PIMAC_FAST_MODE = initial;
  const events = new Map();
  const commands = new Map();
  factory({
    on: (name, handler) => events.set(name, handler),
    registerCommand: (name, command) => commands.set(name, command),
  });
  const statuses = [];
  const ctx = {
    model: { provider: "openai-codex", api: "openai-codex-responses" },
    isIdle: () => true,
    ui: { setStatus: (...args) => statuses.push(args) },
  };
  return { events, commands, ctx, statuses };
}

const desktop = setup("0");
const remote = setup("1");
const payload = { model: "gpt-5.4", input: [] };
const request = { payload };
for (const instance of [desktop, remote])
  instance.events.get("session_start")({}, instance.ctx);
assert.deepEqual(desktop.statuses.at(-1), ["pimac-fast", "off"]);
assert.deepEqual(remote.statuses.at(-1), ["pimac-fast", "on"]);
assert.equal(desktop.events.get("before_provider_request")(request, desktop.ctx), undefined);
assert.deepEqual(remote.events.get("before_provider_request")(request, remote.ctx), {
  ...payload, service_tier: "priority",
});
assert.equal(payload.service_tier, undefined, "Never mutate the original payload");
await desktop.commands.get("pimac-fast").handler("on", desktop.ctx);
assert.deepEqual(desktop.statuses.at(-1), ["pimac-fast", "on"]);
assert.equal(desktop.events.get("before_provider_request")(request, {
  ...desktop.ctx, model: { provider: "google" },
}), undefined);
await desktop.commands.get("pimac-fast").handler("off", desktop.ctx);
assert.equal(desktop.events.get("before_provider_request")(request, desktop.ctx), undefined);
assert.equal(remote.events.get("before_provider_request")(request, remote.ctx).service_tier, "priority");
await assert.rejects(desktop.commands.get("pimac-fast").handler("invalid", desktop.ctx));
await assert.rejects(desktop.commands.get("pimac-fast").handler("on", {
  ...desktop.ctx, isIdle: () => false,
}));
assert.equal(remote.events.get("before_provider_request")(request, {
  ...remote.ctx, model: { provider: "openai", api: "openai-responses" },
}).service_tier, "priority");
for (const model of [
  { provider: "openai", api: "openai-completions" },
  { provider: "openai-codex", api: "pi-virtual" },
  { provider: "openai", api: "pi-virtual" },
  { provider: "custom", api: "openai-responses" },
]) assert.equal(remote.events.get("before_provider_request")(request, { ...remote.ctx, model }), undefined);
for (const payload of [null, [], "text"])
  assert.equal(remote.events.get("before_provider_request")({ payload }, remote.ctx), undefined);
console.log("Fast extension tests passed");
