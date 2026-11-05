import assert from "node:assert/strict";
import test from "node:test";
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { runtimeRoot, managedSettings } from "../../../scripts/manage-pi-runtime.ts";

test("managed configuration is idempotent, removes external duplicates and retains unrelated packages", () => {
  const result = managedSettings({ packages: ["npm:pi-antigravity", "npm:pi-web-access", "npm:pi-goal-x@0.32.3", "npm:other"], retry: { enabled: true } });
  assert.equal(result.packages.length, 4);
  assert.equal(result.packages[0], "npm:other");
  assert.deepEqual(managedSettings(result), result);
  assert.throws(() => managedSettings({ packages: false }));
});

test("Pi 1.5 loads all managed extensions with original exports and handles a real offline provider request", { timeout: 30000 }, async () => {
  const repository = fileURLToPath(new URL("../../../", import.meta.url));
  const parent = join(repository, "tmp/managed-modules");
  await mkdir(parent, { recursive: true });
  const work = await mkdtemp(join(parent, "compat-"));
  const tools = join(work, "tools.json");
  const wrapper = join(work, "extensions.ts");
  await writeFile(wrapper, `import { writeFileSync } from "node:fs";
    import antigravity from ${JSON.stringify(join(runtimeRoot, "node_modules/pi-antigravity/src/index.ts"))};
    import search from ${JSON.stringify(join(runtimeRoot, "node_modules/pi-antigravity/src/features/google-search.ts"))};
    import image from ${JSON.stringify(join(runtimeRoot, "node_modules/pi-antigravity/src/features/generate-image.ts"))};
    import web from ${JSON.stringify(join(runtimeRoot, "node_modules/pi-web-access/dist/index.js"))};
    import goal from ${JSON.stringify(join(repository, "extensions/pi-goal/index.ts"))};
    import accounts from ${JSON.stringify(join(repository, "extensions/account-usage/index.ts"))};
    import provider from ${JSON.stringify(join(repository, "scripts/fixtures/pi-retry.ts"))};
    export default async function(pi) {
      const registered = [];
      const observed = new Proxy(pi, { get(target, key) {
        if (key !== "registerTool") return target[key];
        return tool => { registered.push(tool.name); target.registerTool(tool); };
      } });
      for (const extension of [antigravity, search, image, web, goal, accounts, provider]) await extension(observed);
      writeFileSync(${JSON.stringify(tools)}, JSON.stringify(registered));
    }`);
  const cli = join(runtimeRoot, "node_modules/@earendil-works/pi-coding-agent/dist/bundle/cli.js");
  const child = spawn(process.execPath, [cli, "--mode", "rpc", "--no-session", "--no-extensions", "--no-skills", "--no-prompt-templates", "-e", wrapper,
    "--provider", "pimac-retry-test", "--model", "offline"], {
    cwd: work, env: { ...process.env, PI_CODING_AGENT_DIR: join(work, "agent"), HOME: work, PI_OFFLINE: "1", PI_SKIP_VERSION_CHECK: "1", PI_TELEMETRY: "0" },
    stdio: ["pipe", "pipe", "pipe"],
  });
  const events: Record<string, any>[] = [];
  let buffer = "", stderr = "", exited = false;
  child.stdout.setEncoding("utf8").on("data", text => {
    buffer += text;
    let end: number;
    while ((end = buffer.indexOf("\n")) >= 0) {
      events.push(JSON.parse(buffer.slice(0, end))); buffer = buffer.slice(end + 1);
    }
  });
  child.stderr.setEncoding("utf8").on("data", text => { stderr += text; });
  const closed = new Promise<void>(done => child.once("close", () => { exited = true; done(); }));
  const until = async (predicate: () => boolean) => {
    const deadline = Date.now() + 15000;
    while (!predicate()) {
      if (exited || Date.now() > deadline) throw Error(`${stderr}\n${JSON.stringify(events.slice(-5))}`);
      await new Promise(done => setTimeout(done, 10));
    }
  };
  try {
    child.stdin.write(JSON.stringify({ id: "commands", type: "get_commands" }) + "\n");
    await until(() => events.some(e => e.type === "response" && e.id === "commands"));
    const response = events.find(e => e.type === "response" && e.id === "commands")!;
    assert.equal(response.success, true, stderr);
    const commands = response.data.commands.map((c: { name: string }) => c.name);
    assert(commands.includes("goal")); assert(commands.includes("antigravity.doctor"));
    assert.equal(commands.filter((name: string) => name === "goal").length, 1);
    const registered = JSON.parse(await readFile(tools, "utf8")) as string[];
    for (const tool of ["google_search", "generate_image", "web_search", "fetch_content", "goal_complete", "goal_blocked"]) assert(registered.includes(tool), tool);
    child.stdin.write(JSON.stringify({ id: "prompt", type: "prompt", message: "401 Unauthorized" }) + "\n");
    await until(() => events.some(e => e.type === "agent_settled"));
    assert(events.some(e => e.type === "message_end" && e.message?.errorMessage === "401 Unauthorized"));
    assert(!events.some(e => e.type === "extension_error"), JSON.stringify(events.filter(e => e.type === "extension_error")));
  } finally {
    child.stdin.end();
    if (!exited) child.kill("SIGTERM");
    await closed;
  }
});
