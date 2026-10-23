import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export const goalPackage = "npm:pi-goal-x@0.32.3";
export const goalBridgePatches = [
  {
    file: "goal-state.ts",
    sha256: "9169cff7f735da0e7d62e65d82516ca602dfa0871ef3f1a9b6ca8977f5283e1e",
    anchor: "\tfunction updateUI(ctx: ExtensionContext): void {\n\t\tif (!ctx.hasUI) return;",
    replacement: `\tlet lastPiMacGoalStatus: string | undefined;
\tlet lastPiMacGoalSession: string | undefined;
\tfunction updateUI(ctx: ExtensionContext): void {
\t\t// 只桥接权威内存状态；不改变持久化、审计或自动续跑的所有权。
\t\tif (ctx.mode === "rpc") {
\t\t\tconst goal = state.goal;
\t\t\tconst status = JSON.stringify({ version: 1, goal: goal ? {
\t\t\t\tobjective: goal.objective, status: goal.status,
\t\t\t\ttokensUsed: Math.floor(goal.usage.tokensUsed),
\t\t\t\ttimeUsedSeconds: Math.floor(goal.usage.activeSeconds),
\t\t\t\t...(goal.tokenBudget === undefined ? {} : { tokenBudget: goal.tokenBudget }),
\t\t\t} : null });
\t\t\tconst session = ctx.sessionManager.getSessionId();
\t\t\tif (status !== lastPiMacGoalStatus || session !== lastPiMacGoalSession) {
\t\t\t\tctx.ui.setStatus("pimac-goal", status);
\t\t\t\tlastPiMacGoalStatus = status;
\t\t\t\tlastPiMacGoalSession = session;
\t\t\t}
\t\t}
\t\tif (!ctx.hasUI) return;`,
  },
  {
    file: "goal-events.ts",
    sha256: "c1d76993741c70460e1886bf04b5f633f5da41f591d943dacea24c2b1ad4d63f",
    anchor: "\t\tawait core.loadState(ctx);\n\t\tcore.installGoalToolProfile",
    replacement: "\t\tawait core.loadState(ctx);\n\t\tcore.updateUI(ctx); // 启动时也明确发布合法空状态，清除旧的服务端投影。\n\t\tcore.installGoalToolProfile",
  },
];
const hash = (text: string): string => createHash("sha256").update(text).digest("hex");

export function bridgeGoalSource(file: string, source: string): string {
  const patch = goalBridgePatches.find((item) => item.file === file);
  if (!patch) throw new Error(`Unknown Goal bridge file: ${file}`);
  // 重复执行只接受完全一致的补丁，不覆盖用户改动或未知上游版本。
  const original = source.includes(patch.replacement)
    ? source.replace(patch.replacement, patch.anchor) : source;
  if (hash(original) !== patch.sha256 || original.split(patch.anchor).length !== 2) {
    throw new Error(`Goal source differs from pinned 0.32.3: ${file}`);
  }
  return original.replace(patch.anchor, patch.replacement);
}

export async function installGoalBridge(packageRoot: string, check: boolean): Promise<void> {
  const manifest = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
  if (manifest.name !== "pi-goal-x" || manifest.version !== "0.32.3") {
    throw new Error("Expected pi-goal-x 0.32.3; refusing to patch another package/version");
  }
  // 写入前先验证全部文件，避免第二个锚点失败时留下半套桥接。
  const files = await Promise.all(goalBridgePatches.map(async ({ file }) => {
    const path = join(packageRoot, "extensions", file);
    const source = await readFile(path, "utf8");
    return { path, source, patched: bridgeGoalSource(file, source) };
  }));
  for (const { path, source, patched } of files) {
    if (check && source !== patched) throw new Error(`Goal bridge missing: ${path}`);
    if (!check && source !== patched) await writeFile(path, patched);
  }
}

if (require.main === module) {
  const check = process.argv.includes("--check");
  if (!check) execFileSync("pi", ["install", goalPackage], { stdio: "inherit" });
  const agent = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
  installGoalBridge(join(agent, "npm", "node_modules", "pi-goal-x"), check)
    .then(() => console.log(`Goal bridge ${check ? "verified" : "installed"}. Existing sessions are not restarted.`))
    .catch((error: unknown) => { console.error(error); process.exitCode = 1; });
}
