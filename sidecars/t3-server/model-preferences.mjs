import fs from 'node:fs';
import path from 'node:path';

// 只迁移已发布版本的私有文件；官方写锁保证已有 Server 偏好不被旧文件覆盖。
export async function migrateModelPreferences(directory, updateSettings) {
  let value;
  try {
    value = JSON.parse(fs.readFileSync(path.join(directory, 'model-preferences.json'), 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return;
    throw error;
  }
  if (!value || !Array.isArray(value.hiddenModels) || !value.hiddenModels.every(id => typeof id === 'string' && id.trim())) {
    throw new Error('Invalid legacy model preferences');
  }
  await updateSettings({ migrateModelPreferences: { providerModelPreferences: {
    pi: { hiddenModels: [...new Set(value.hiddenModels)], modelOrder: [] },
  } } });
}

export function visibleProviders(providers, settings) {
  // 仅派生展示目录，不过滤运行注册表；每个实例遵循自己的官方偏好。
  return providers.filter(provider => provider.enabled !== false).map(provider => {
    const hidden = new Set(settings.providerModelPreferences?.[provider.instanceId]?.hiddenModels ?? []);
    return { ...provider, models: provider.models.filter(model => !hidden.has(model.slug)) };
  });
}
