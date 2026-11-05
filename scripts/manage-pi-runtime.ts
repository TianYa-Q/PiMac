import { readFile, writeFile, mkdir, rename } from "node:fs/promises";
import { execFileSync } from "node:child_process";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { installPiRetry } from "./install-pi-retry.ts";

export const runtimeRoot = fileURLToPath(new URL("../extensions/runtime", import.meta.url));
const repository = fileURLToPath(new URL("../", import.meta.url));
export const runtimeManifestPath = join(homedir(), "Library/Application Support/PiMac/ManagedRuntime/modules.json");
const engine = "@earendil-works/pi-coding-agent";
const modules = [engine, "pi-antigravity", "pi-web-access", "@schovest/pi-goal"];

export function managedSettings<T extends Record<string, unknown>>(settings: T) {
  if (settings.packages !== undefined && !Array.isArray(settings.packages)) throw new Error("Invalid packages setting");
  const packages = (settings.packages ?? []) as unknown[];
  const retained = packages.filter(item => {
    const source = typeof item === "string" ? item :
      item && typeof item === "object" && "source" in item ? item.source : undefined;
    if (typeof source !== "string") throw new Error("Invalid package source");
    return !/^npm:(?:pi-antigravity|pi-web-access|pi-goal-x|@schovest\/pi-goal)(?:@|$)/u.test(source) &&
      source !== join(repository, "extensions/pi-goal") &&
      !["pi-antigravity", "pi-web-access"].some(name => source === join(runtimeRoot, "node_modules", name));
  });
  return { ...settings, packages: [...retained,
    join(runtimeRoot, "node_modules/pi-antigravity"),
    join(runtimeRoot, "node_modules/pi-web-access"),
    join(repository, "extensions/pi-goal"),
  ] };
}

export async function activateManagedRuntime(agent: string, check: boolean) {
  const manifest = JSON.parse(await readFile(join(runtimeRoot, "package.json"), "utf8"));
  const installed = [];
  for (const name of modules) {
    const packagePath = join(runtimeRoot, "node_modules", name, "package.json");
    const pkg = JSON.parse(await readFile(packagePath, "utf8"));
    if (pkg.name !== name || pkg.version !== manifest.dependencies[name]) throw new Error(`Module version mismatch: ${name}`);
    installed.push({ name, version: pkg.version, manifestPath: packagePath });
  }
  for (const name of ["account-usage", "pi-goal"]) {
    const packagePath = join(repository, "extensions", name, "package.json");
    const pkg = JSON.parse(await readFile(packagePath, "utf8"));
    installed.push({ name: name === "pi-goal" ? "PiMac Goal 适配器" : "账户管理", version: pkg.version, manifestPath: packagePath });
  }
  // 使用 Pi 官方设置存储锁，只更换已由 PiMac 接管的模块，不覆盖并发账户/模型设置。
  const { FileSettingsStorage } = await import(pathToFileURL(join(runtimeRoot, "node_modules", engine, "dist/core/settings-manager.js")).href);
  const storage = new FileSettingsStorage(process.cwd(), agent);
  storage.withLock("global", (text: string | undefined) => {
    const current = text === undefined ? {} : JSON.parse(text);
    const next = managedSettings(current);
    if (check) {
      if (JSON.stringify(next) !== JSON.stringify(current)) throw new Error("Managed module selection not active");
      return undefined;
    }
    return JSON.stringify(next) === JSON.stringify(current) ? undefined : JSON.stringify(next, null, 2) + "\n";
  });
  const receipt = { schemaVersion: 1,
    executable: join(runtimeRoot, "node_modules/.bin/pi"), modules: installed };
  if (check) {
    if (JSON.stringify(JSON.parse(await readFile(runtimeManifestPath, "utf8"))) !== JSON.stringify(receipt)) throw new Error("Managed runtime receipt differs");
  } else {
    await mkdir(resolve(runtimeManifestPath, ".."), { recursive: true });
    const staging = `${runtimeManifestPath}.${process.pid}`;
    await writeFile(staging, JSON.stringify(receipt, null, 2) + "\n", { mode: 0o600, flag: "wx" });
    await rename(staging, runtimeManifestPath);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const check = process.argv.includes("--check");
  const agent = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi/agent");
  if (!check) {
    for (const directory of [runtimeRoot, join(repository, "extensions/pi-goal"), join(repository, "extensions/account-usage")]) {
      execFileSync("npm", ["ci", "--ignore-scripts", "--legacy-peer-deps", "--prefix", directory], { stdio: "inherit" });
    }
    execFileSync("sh", [join(repository, "scripts/link-account-usage.sh")], {
      stdio: "inherit", env: { ...process.env, PI_CODING_AGENT_DIR: agent },
    });
  }
  await installPiRetry(join(runtimeRoot, "node_modules", engine), agent, check);
  await activateManagedRuntime(agent, check);
  console.log(`PiMac internal modules ${check ? "verified" : "activated"}. Running processes were not restarted.`);
}
