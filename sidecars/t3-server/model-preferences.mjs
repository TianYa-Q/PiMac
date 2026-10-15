import fs from 'node:fs';
import path from 'node:path';

// Shared chooser/status visibility only. Never filter the runtime registry or routing.
let file;
let hiddenModels = new Set();
const listeners = new Set();
export function configureModelPreferences(directory) {
  file = path.join(directory, 'model-preferences.json');
  hiddenModels = new Set();
  try {
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    if (Array.isArray(value.hiddenModels) && value.hiddenModels.every(id => typeof id === 'string')) {
      hiddenModels = new Set(value.hiddenModels);
    }
  } catch (error) {
    if (error.code !== 'ENOENT') console.warn('Could not load model visibility preferences');
  }
}
export function setModelPreferences(value) {
  if (!value || !Array.isArray(value.hiddenModels) || !value.hiddenModels.every(id => typeof id === 'string') ||
      !(value.defaultModel === null || typeof value.defaultModel === 'string')) throw new Error('Invalid model preferences');
  const next = { hiddenModels: [...new Set(value.hiddenModels)], defaultModel: value.defaultModel };
  if (file) {
    const temporary = file + '.tmp';
    fs.writeFileSync(temporary, JSON.stringify(next), { mode: 0o600 });
    fs.renameSync(temporary, file);
  }
  hiddenModels = new Set(next.hiddenModels);
  for (const listener of listeners) listener();
}
export async function syncModelPreferences(value, updateSettings) {
  setModelPreferences(value);
  const model = value.defaultModel && !value.hiddenModels.includes(value.defaultModel) ? value.defaultModel : null;
  await updateSettings({ defaultModelSelection: model ? { instanceId: 'pi', model } : null });
  return { ok: true };
}
export function subscribeModelPreferences(listener) {
  listeners.add(listener);
  listener(); // Replay to close the snapshot/subscription race.
  return () => listeners.delete(listener);
}
export function visibleProviders(providers) {
  // 隐藏已关闭实例的状态行；启用任意官方驱动后自动出现，不按 driver 白名单过滤。
  return providers.filter(provider => provider.enabled !== false).map(provider => provider.driver === 'pi'
    ? { ...provider, models: provider.models.filter(model => !hiddenModels.has(model.slug)) }
    : provider);
}
