import { createHash } from "node:crypto";
import { readFile, realpath, rename, writeFile } from "node:fs/promises";
import { findPackageJSON } from "node:module";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { pathToFileURL } from "node:url";

// 只补设置解析和错误分类；沿用 Pi 的重试、退避、取消、历史投影及汇总循环。
// Infinity 只在内存使用，JSON RPC 自动编码成 null，T3 原生契约用 null 表示无上限。
const settingsAnchor = "this.settings.retry?.maxRetries ?? SETTINGS_DEFAULTS.retry.maxRetries";
const settingsReplacement = "this.settings.retry?.unlimited === true ? Infinity : (this.settings.retry?.maxRetries ?? SETTINGS_DEFAULTS.retry.maxRetries)";
export const permanentErrors = String.raw`\\b(?:400|401|403|404|405|413|415|422)\\b|unauthori[sz]ed|forbidden|authentication[_ -]?error|permission[_ -]?denied|invalid[_ -]?request|invalid.{0,20}api.{0,5}key|api.{0,5}key.{0,20}invalid`;
const transportErrors = String.raw`\\b(?:ECONNRESET|ECONNREFUSED|ETIMEDOUT|ENOTFOUND|EAI_AGAIN)\\b`;
export const piRetryPatches = [
  { owner: "agent", file: "dist/core/settings-manager.js",
    sha256: "66edb495ff9767e7f2ce0d2f4e2d102532e4b396ad7bc7c3c648c7c12c0fe71d",
    edits: [{ oldText: settingsAnchor, newText: settingsReplacement }] },
  { owner: "agent", file: "dist/bundle/chunks/chunk-44DLKSKE.js",
    sha256: "e52d27d064df05fe8ec15f05db07d7c895051597551a0d62b2fe77208d88e942",
    edits: [{ oldText: settingsAnchor.replaceAll(" ", ""), newText: settingsReplacement }] },
  { owner: "agent", file: "dist/bundle/chunks/chunk-62VOPMLK.js",
    sha256: "5c961be45765d1c3676c476c8777177a002a672ee67f7b8af6b554f2437f7ad4",
    edits: [
      { oldText: 'NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN=buildProviderErrorPattern(["GoUsageLimitError"',
        newText: `NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN=buildProviderErrorPattern(["${permanentErrors}","GoUsageLimitError"` },
      { oldText: 'RETRYABLE_PROVIDER_ERROR_PATTERN=buildProviderErrorPattern(["overloaded"',
        newText: `RETRYABLE_PROVIDER_ERROR_PATTERN=buildProviderErrorPattern(["${transportErrors}","overloaded"` },
    ] },
  { owner: "ai", file: "dist/utils/retry.js",
    sha256: "6ab3ea07994c28824374681d4b0c8055d42b5f9eaccb1702573f3a95b371bfd7",
    edits: [
      { oldText: 'const NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN = buildProviderErrorPattern([',
        newText: `const NON_RETRYABLE_PROVIDER_LIMIT_ERROR_PATTERN = buildProviderErrorPattern([\n    "${permanentErrors}",` },
      { oldText: 'const RETRYABLE_PROVIDER_ERROR_PATTERN = buildProviderErrorPattern([',
        newText: `const RETRYABLE_PROVIDER_ERROR_PATTERN = buildProviderErrorPattern([\n    "${transportErrors}",` },
    ] },
] as const;

export function patchPiRetrySource(source: string, patch: typeof piRetryPatches[number]): string {
  let original = source;
  for (const edit of [...patch.edits].reverse()) {
    if (original.includes(edit.newText)) original = original.replace(edit.newText, edit.oldText);
  }
  if (createHash("sha256").update(original).digest("hex") !== patch.sha256 ||
      patch.edits.some(({ oldText }) => original.split(oldText).length !== 2)) {
    throw new Error(`Pi retry source differs from pinned 1.5.0: ${patch.file}`);
  }
  return patch.edits.reduce((text, edit) => text.replace(edit.oldText, edit.newText), original);
}

export async function installPiRetry(packageRoot: string, agentDir: string, check: boolean): Promise<void> {
  const root = await realpath(packageRoot);
  const aiManifest = findPackageJSON("@earendil-works/pi-ai", pathToFileURL(join(root, "dist/index.js")).href);
  if (!aiManifest) throw new Error("Pi AI dependency not found");
  const aiRoot = dirname(aiManifest);
  for (const [path, name] of [[root, "@earendil-works/pi-coding-agent"], [aiRoot, "@earendil-works/pi-ai"]]) {
    const manifest = JSON.parse(await readFile(join(path!, "package.json"), "utf8"));
    if (manifest.name !== name || manifest.version !== "1.5.0") throw new Error(`Expected ${name}@1.5.0`);
  }
  // 所有原文先通过哈希校验；未知版本/本地改动不允许覆盖。临时文件与 rename 避免修改 pnpm 硬链接的其他实例。
  const files = await Promise.all(piRetryPatches.map(async (patch) => {
    const path = join(patch.owner === "ai" ? aiRoot : root, patch.file);
    const source = await readFile(path, "utf8");
    return { path, source, patched: patchPiRetrySource(source, patch) };
  }));
  for (const { path, source, patched } of files) {
    if (check && source !== patched) throw new Error(`Pi retry patch missing: ${path}`);
    if (!check && source !== patched) {
      if (await readFile(path, "utf8") !== source) throw new Error(`Pi source changed during installation: ${path}`);
      const staging = `${path}.pimac-retry-${process.pid}`;
      await writeFile(staging, patched, { flag: "wx" });
      await rename(staging, path);
    }
  }
  // 使用上游存储锁，只合并 retry 字段，不覆盖其他任务写入的账户/模型等设置。
  const { FileSettingsStorage } = await import(pathToFileURL(join(root, "dist/core/settings-manager.js")).href);
  const storage = new FileSettingsStorage(process.cwd(), agentDir);
  storage.withLock("global", (current: string | undefined) => {
    const settings = current === undefined ? {} : JSON.parse(current);
    if (!settings || typeof settings !== "object" || Array.isArray(settings) ||
        (settings.retry !== undefined && (!settings.retry || typeof settings.retry !== "object" || Array.isArray(settings.retry)))) {
      throw new Error("Invalid Pi retry settings; existing settings retained");
    }
    const desired = { enabled: true, unlimited: true, baseDelayMs: 2_000, maxAgentDelayMs: 60_000 };
    if (check) {
      if (Object.entries(desired).some(([key, value]) => settings.retry?.[key] !== value)) {
        throw new Error("Pi persistent retry settings missing");
      }
      return undefined;
    }
    settings.retry = { ...settings.retry, ...desired };
    return JSON.stringify(settings, null, 2) + "\n";
  });
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const root = process.argv[process.argv.indexOf("--package-root") + 1];
  if (!process.argv.includes("--package-root") || !root || root.startsWith("--")) {
    throw new Error("Usage: tsx scripts/install-pi-retry.ts --package-root <pi-coding-agent@1.5.0 directory> [--check]");
  }
  installPiRetry(root, process.env.PI_CODING_AGENT_DIR ?? join(homedir(), ".pi", "agent"), process.argv.includes("--check"))
    .then(() => console.log("Pi persistent retry installed/verified; no process restarted."))
    .catch((error: unknown) => { console.error(error); process.exitCode = 1; });
}
