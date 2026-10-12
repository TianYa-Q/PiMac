import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

const object = value => value !== null && typeof value === 'object' && !Array.isArray(value);
const validTokens = value => Number.isSafeInteger(value) && value > 0;
const discoveredDefaults = new Map();

export function createModelContextSettings(agentDirectory = process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), '.pi', 'agent')) {
  const directory = agentDirectory === '~' ? os.homedir() : agentDirectory.startsWith('~/')
    ? path.join(os.homedir(), agentDirectory.slice(2)) : agentDirectory;
  const file = path.join(directory, 'models.json');
  function read() {
    let config;
    try {
      const stat = fs.lstatSync(file);
      if (!stat.isFile()) throw new Error('Pi models.json must be a regular file');
      config = JSON.parse(fs.readFileSync(file, 'utf8'));
    } catch (error) {
      if (error.code === 'ENOENT') return {};
      throw new Error('Could not read Pi models.json; existing configuration was not changed', { cause: error });
    }
    if (!object(config) || (config.providers !== undefined && !object(config.providers))) {
      throw new Error('Invalid Pi models.json providers');
    }
    return config;
  }
  function overrides(config) {
    const result = {};
    for (const [provider, settings] of Object.entries(config.providers ?? {})) {
      if (!object(settings) || (settings.modelOverrides !== undefined && !object(settings.modelOverrides))) {
        throw new Error('Invalid Pi model overrides');
      }
      for (const [model, override] of Object.entries(settings.modelOverrides ?? {})) {
        if (!object(override) || (override.contextWindow !== undefined && !validTokens(override.contextWindow))) {
          throw new Error('Invalid Pi model context window');
        }
        if (override.contextWindow !== undefined) result[`${provider}/${model}`] = override.contextWindow;
      }
    }
    return result;
  }
  return {
    snapshot() { return { overrides: overrides(read()), defaults: discoveredDefaults.get(file) ?? {} }; },
    recordModels(data) {
      if (!object(data) || !Array.isArray(data.models)) throw new Error('Invalid Pi model discovery response');
      const configured = overrides(read());
      const defaults = {};
      // 只将未被手工覆盖的 Pi 原始模型额度称为默认值。覆盖后的 contextWindow 不能反推基础额度。
      // 每次发现替换整个快照，避免移除覆盖后把上一轮已覆盖的值误标成默认。
      for (const model of data.models) {
        if (!object(model) || typeof model.provider !== 'string' || typeof model.id !== 'string' ||
            !model.provider || !model.id || model.contextWindow === undefined) continue;
        if (!validTokens(model.contextWindow)) throw new Error('Invalid Pi discovered context window');
        const id = `${model.provider}/${model.id}`;
        if (!Object.hasOwn(configured, id)) defaults[id] = model.contextWindow;
      }
      discoveredDefaults.set(file, defaults);
    },
    set(input) {
      if (!object(input) || Object.keys(input).length !== 2 || typeof input.modelId !== 'string' ||
          !(input.tokens === null || validTokens(input.tokens))) throw new Error('Invalid model context setting');
      const slash = input.modelId.indexOf('/');
      const provider = input.modelId.slice(0, slash), model = input.modelId.slice(slash + 1);
      if (slash < 1 || !model || input.modelId.trim() !== input.modelId || /[\u0000-\u001f]/.test(input.modelId) ||
          [provider, model].some(key => ['__proto__', 'constructor', 'prototype'].includes(key))) {
        throw new Error('Invalid model identifier');
      }
      // 每次保存都重新读取，以模型级补丁保留 API 凭据、其他模型及手工配置；损坏文件不能降级为空配置。
      const config = read();
      overrides(config);
      const providers = config.providers ?? {};
      const settings = Object.hasOwn(providers, provider) ? providers[provider] : {};
      const models = settings.modelOverrides ?? {};
      const override = { ...(Object.hasOwn(models, model) ? models[model] : {}) };
      if (input.tokens === null) delete override.contextWindow;
      else override.contextWindow = input.tokens;
      if (Object.keys(override).length) models[model] = override;
      else delete models[model];
      if (Object.keys(models).length) settings.modelOverrides = models;
      else delete settings.modelOverrides;
      if (Object.keys(settings).length) providers[provider] = settings;
      else delete providers[provider];
      config.providers = providers;
      // Pi 的 modelOverrides 是最高优先级元数据层，内置、远程和自定义模型均使用同一写入路径。
      // 不修改运行中的 Pi 会话；新进程或 Pi 重新加载模型目录后才采用此值。
      fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
      const temporary = path.join(directory, `.models-${randomUUID()}.tmp`);
      fs.writeFileSync(temporary, JSON.stringify(config, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
      fs.renameSync(temporary, file);
      return { overrides: overrides(config), defaults: discoveredDefaults.get(file) ?? {} };
    },
  };
}
