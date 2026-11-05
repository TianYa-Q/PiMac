import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { permanentErrors } from "./install-pi-retry.ts";

export const goalPackage = "npm:pi-goal-x@0.32.3";
export const goalBridgePatches = [
  {
    file: "goal-commands.ts",
    sha256: "b28d51d448da7f4ca8ebdfe532d782f1e84adf61ec43cfcf043df4a1882d5b55",
    anchor: '\t\tif (!core.state.goal && otherOpenGoalCount(core.goalsById, null) > 0) {\n\t\t\tconst selected = await chooseOpenGoal(ctx, "Clear which open goal?");',
    replacement: '\t\t// RPC 的清除动作只针对当前焦点，不弹选择器，也不触碰其他开放目标。\n\t\tif (ctx.mode !== "rpc" && !core.state.goal && otherOpenGoalCount(core.goalsById, null) > 0) {\n\t\t\tconst selected = await chooseOpenGoal(ctx, "Clear which open goal?");',
  },
  {
    file: "goal-commands.ts",
    sha256: "b28d51d448da7f4ca8ebdfe532d782f1e84adf61ec43cfcf043df4a1882d5b55",
    anchor: '\t\tif (!ctx.hasUI) {\n\t\t\tctx.ui.notify(`Run /goal-clear in an interactive session to confirm clearing: ${oneLineSummary(target)}`, "warning");',
    replacement: '\t\tif (!ctx.hasUI && ctx.mode !== "rpc") {\n\t\t\tctx.ui.notify(`Run /goal-clear in an interactive session to confirm clearing: ${oneLineSummary(target)}`, "warning");',
  },
  {
    file: "goal-commands.ts",
    sha256: "b28d51d448da7f4ca8ebdfe532d782f1e84adf61ec43cfcf043df4a1882d5b55",
    anchor: '\t\tconst confirmed = await ctx.ui.confirm("Clear goal?", oneLineSummary(target));',
    replacement: '\t\t// RPC 中点击 Clear Goal 或显式输入命令本身即为用户授权；仍沿用原扩展归档与焦点校验。\n\t\tconst confirmed = ctx.mode === "rpc" || await ctx.ui.confirm("Clear goal?", oneLineSummary(target));',
  },
  {
    file: "goal-events.ts",
    sha256: "c1d76993741c70460e1886bf04b5f633f5da41f591d943dacea24c2b1ad4d63f",
    anchor: "\t\tnetworkErrorRecoveryAfterSettleFor = null;\n\t\tcore.scheduler.settled(ctx, !!goalId && core.isActionableContinuationGoal(goalId));",
    replacement: `\t\tnetworkErrorRecoveryAfterSettleFor = null;
\t\t// 退避期间的停止发生在 agent_end 之后；最终 aborted 才是权威取消信号。
\t\tif (_event.aborted === true) {
\t\t\tcore.runtime.clearNetworkErrorBackoff();
\t\t\tif ((goalId && core.isActionableContinuationGoal(goalId)) ||
\t\t\t\t(networkErrorGoalId && core.isActionableContinuationGoal(networkErrorGoalId))) {
\t\t\t\tcore.pauseActiveGoal(ctx);
\t\t\t}
\t\t\treturn;
\t\t}
\t\tcore.scheduler.settled(ctx, !!goalId && core.isActionableContinuationGoal(goalId));`,
  },
  {
    file: "goal-format.ts",
    sha256: "d613ecd5882a7a8b0ec290da34f41a9fe375c9dbad87452ec31e7a1bf923f128",
    anchor: "const NON_TRANSIENT_PROVIDER_ERROR_RE = new RegExp(\n\t[",
    replacement: `const NON_TRANSIENT_PROVIDER_ERROR_RE = new RegExp(\n\t[\n\t\t"${permanentErrors}",`,
  },
  {
    file: "goal-format.ts",
    sha256: "d613ecd5882a7a8b0ec290da34f41a9fe375c9dbad87452ec31e7a1bf923f128",
    anchor: '\t\t"\\\\bnetwork[_\\\\s-]?error\\\\b",',
    // 只补传输错误识别；退避、重试次数和用户停止仍由原扩展负责。
    replacement: String.raw`		"\\bnetwork[_\\s-]?error\\b",
		"\\bfetch failed\\b",
		"\\b(?:ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EAI_AGAIN)\\b",
		"\\bsocket hang up\\b",
		"\\bother side closed\\b",`,
  },
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
  {
    file: "goal-events.ts",
    sha256: "c1d76993741c70460e1886bf04b5f633f5da41f591d943dacea24c2b1ad4d63f",
    anchor: "\t\t// Codex behavior: prompt before reactivating a paused goal on resume.\n\t\tif (event.reason === \"resume\" && core.state.goal?.status === \"paused\" && ctx.hasUI) {\n\t\t\tconst current = core.state.goal;\n\t\t\tconst shouldResume = await ctx.ui.confirm(\"Resume paused goal?\", `Goal: ${current.objective}`);\n\t\t\tif (shouldResume) {\n\t\t\t\tcore.scheduler.resume(ctx);\n\t\t\t}\n\t\t}\n",
    replacement: "\t\t// 暂停是持久的用户选择；重连会话不代表请求恢复，也不弹出恢复确认。\n",
  },
  {
    file: "goal-events.ts",
    sha256: "c1d76993741c70460e1886bf04b5f633f5da41f591d943dacea24c2b1ad4d63f",
    anchor: "The goal is paused. Do not autonomously continue substantive work unless the user resumes it with /goal-resume.",
    replacement: "The goal is paused. Handle the user's current message normally, including explicitly requested independent tasks; pausing this goal does not pause the conversation. Do not ask, remind, or suggest that the user resume the goal, and do not make resuming it a prerequisite for answering or doing independent work. Ordinary messages, related discussion, and session reconnection are not consent to resume. Keep the goal paused and do not autonomously continue its work; resumption is an explicit user action via /goal-resume.",
  },
  {
    file: "goal-events.ts",
    sha256: "c1d76993741c70460e1886bf04b5f633f5da41f591d943dacea24c2b1ad4d63f",
    anchor: `		if (event.reason === "resume" && !core.state.goal && !core.hasExplicitSessionFocus && otherOpenGoalCount(core.goalsById, null) > 1 && ctx.hasUI) {
			// Prompt the user to pick which open goal to focus (mirrors /goal-focus).
			const open = core.openGoals();
			const labels = open.map((item) => goalSelectorLabel(item, core.focusedGoalId));
			const byLabel = new Map(labels.map((label, index) => [label, open[index]?.id]));
			core.enterGoalModal();
			try {
				const selected = await ctx.ui.select("Focus open goal", labels);
				const selectedId = selected ? byLabel.get(selected) : undefined;
				if (selectedId) {
					core.setFocusedGoalId(selectedId, ctx, "selected");
					core.armFocusedContinuation(ctx);
				}
			} finally {
				core.exitGoalModal();
			}
		}
`,
    replacement: "\t\t// 恢复会话不代表选择目标；仅由用户主动通过 /goal-focus 打开选择器。\n",
  },
];
// 独立增量补丁保留已发布桥接的还原锚点，使现有安装也能通过原文哈希校验升级。
goalBridgePatches.push({
  file: "goal-state.ts",
  sha256: "9169cff7f735da0e7d62e65d82516ca602dfa0871ef3f1a9b6ca8977f5283e1e",
  anchor: "\t\t\t\t...(goal.tokenBudget === undefined ? {} : { tokenBudget: goal.tokenBudget }),",
  replacement: "\t\t\t\t...(goal.tokenBudget === undefined ? {} : { tokenBudget: goal.tokenBudget }),\n\t\t\t\t...(goal.pauseReason === undefined ? {} : { pauseReason: goal.pauseReason }),",
});
const hash = (text: string): string => createHash("sha256").update(text).digest("hex");

export function bridgeGoalSource(file: string, source: string): string {
  const patches = goalBridgePatches.filter((item) => item.file === file);
  if (!patches.length) throw new Error(`Unknown Goal bridge file: ${file}`);
  // 先还原全部已知补丁再校验原文，允许旧版桥接升级；未知改动仍拒绝覆盖。
  let original = source;
  for (const patch of patches.toReversed()) {
    if (original.includes(patch.replacement)) {
      original = original.replace(patch.replacement, patch.anchor);
    }
  }
  if (patches.some((patch) => hash(original) !== patch.sha256)) {
    throw new Error(`Goal source differs from pinned 0.32.3: ${file}`);
  }
  // 增量锚点可能由前一补丁引入，必须按实际应用顺序校验，而不是只在上游原文中查找。
  return patches.reduce((text, patch) => {
    if (text.split(patch.anchor).length !== 2) {
      throw new Error(`Ambiguous or missing Goal bridge anchor: ${file}`);
    }
    return text.replace(patch.anchor, patch.replacement);
  }, original);
}

export async function installGoalBridge(packageRoot: string, check: boolean): Promise<void> {
  const manifest = JSON.parse(await readFile(join(packageRoot, "package.json"), "utf8"));
  if (manifest.name !== "pi-goal-x" || manifest.version !== "0.32.3") {
    throw new Error("Expected pi-goal-x 0.32.3; refusing to patch another package/version");
  }
  // 写入前先验证全部文件，避免第二个锚点失败时留下半套桥接。
  const files = await Promise.all([...new Set(goalBridgePatches.map(({ file }) => file))].map(async (file) => {
    const path = join(packageRoot, "extensions", file);
    const source = await readFile(path, "utf8");
    return { path, source, patched: bridgeGoalSource(file, source) };
  }));
  for (const { path, source, patched } of files) {
    if (check && source !== patched) throw new Error(`Goal bridge missing: ${path}`);
    if (!check && source !== patched) await writeFile(path, patched);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const check = process.argv.includes("--check");
  if (!check) execFileSync("pi", ["install", goalPackage], { stdio: "inherit" });
  const agent = process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent");
  installGoalBridge(join(agent, "npm", "node_modules", "pi-goal-x"), check)
    .then(() => console.log(`Goal bridge ${check ? "verified" : "installed"}. Existing sessions are not restarted.`))
    .catch((error: unknown) => { console.error(error); process.exitCode = 1; });
}
