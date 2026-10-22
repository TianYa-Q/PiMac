import { readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { join, resolve } from 'node:path';
import type { PiThinkingLevel } from './upstream/packages/provider-pi/src/server/thinkingCapabilities.ts';

export interface PiThinkingDefaults {
  readonly defaultLevel: PiThinkingLevel | undefined;
  readonly modelLevels: ReadonlyMap<string, PiThinkingLevel>;
}

const levels = new Set<string>(['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']);

function parseSettings(input: unknown, file: string): PiThinkingDefaults {
  if (typeof input !== 'object' || input === null || Array.isArray(input)) {
    throw new Error(`Invalid Pi settings object in ${file}`);
  }
  const settings = input as Record<string, unknown>;
  const parseLevel = (value: unknown, field: string): PiThinkingLevel => {
    if (typeof value !== 'string' || !levels.has(value)) {
      throw new Error(`Invalid Pi ${field} in ${file}`);
    }
    return value as PiThinkingLevel;
  };
  const defaultLevel = settings.defaultThinkingLevel === undefined ? undefined
    : parseLevel(settings.defaultThinkingLevel, 'defaultThinkingLevel');
  const rawModels = settings.modelThinkingLevels;
  const modelLevels = new Map<string, PiThinkingLevel>();
  if (rawModels !== undefined) {
    if (typeof rawModels !== 'object' || rawModels === null || Array.isArray(rawModels)) {
      throw new Error(`Invalid Pi modelThinkingLevels in ${file}`);
    }
    for (const [model, level] of Object.entries(rawModels)) {
      modelLevels.set(model, parseLevel(level, 'modelThinkingLevels'));
    }
  }
  return { defaultLevel, modelLevels };
}

export async function loadPiThinkingDefaults(
  environment: NodeJS.ProcessEnv,
  cwd: string | undefined,
): Promise<PiThinkingDefaults> {
  const home = environment.HOME ?? homedir();
  const configuredDirectory = environment.PI_CODING_AGENT_DIR;
  const agentDirectory = configuredDirectory
    ? configuredDirectory.replace(/^~(?=$|\/)/, home)
    : join(home, '.pi', 'agent');
  const files = [resolve(cwd ?? process.cwd(), agentDirectory, 'settings.json'),
    resolve(cwd ?? process.cwd(), '.pi', 'settings.json')];
  let defaultLevel: PiThinkingLevel | undefined;
  const modelLevels = new Map<string, PiThinkingLevel>();
  // 与 Pi 的设置合并顺序一致；缺文件是合法空状态，损坏或读取失败不能伪装成默认值缺失。
  for (const file of files) {
    let content: string;
    try { content = await readFile(file, 'utf8'); }
    catch (error) {
      if ((error as NodeJS.ErrnoException).code === 'ENOENT') continue;
      throw error;
    }
    const settings = parseSettings(JSON.parse(content), file);
    defaultLevel = settings.defaultLevel ?? defaultLevel;
    for (const [model, level] of settings.modelLevels) modelLevels.set(model, level);
  }
  return { defaultLevel, modelLevels };
}
