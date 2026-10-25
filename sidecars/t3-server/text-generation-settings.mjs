// 官方 settings 是唯一模型选择来源；此模块只派生可选项，不另存标题模型偏好。
export function createTextGenerationSettings({ readSettings, updateSettings, readProviders, visibleProviders }) {
  let serial = Promise.resolve();
  const exclusive = operation => {
    const result = serial.then(operation);
    serial = result.catch(() => {});
    return result;
  };
  const catalog = async () => {
    const providers = await readProviders();
    if (!Array.isArray(providers) || !providers.some(p => p.instanceId === 'pi' && p.driver === 'pi')) {
      throw new Error('Pi model catalog unavailable');
    }
    const pi = (await visibleProviders(providers)).find(p => p.instanceId === 'pi' && p.driver === 'pi');
    if (!pi) return [];
    if (!Array.isArray(pi.models)) throw new Error('Invalid Pi model catalog');
    if (pi.status === 'error' || pi.auth?.status === 'unknown') {
      throw new Error('Pi model discovery is unavailable; refresh after checking the provider');
    }
    // 官方 Pi 目录始终附带 default 哨兵；它不是具体模型，也可能绕过隐藏列表。
    const models = pi.models.filter(m => m.slug !== 'default');
    if (models.some(m => typeof m.slug !== 'string' || !m.slug.includes('/') || typeof m.name !== 'string')) {
      throw new Error('Invalid Pi model catalog');
    }
    return [...new Map(models.map(m => [m.slug, { id: m.slug, name: m.name }])).values()];
  };
  const snapshot = async (input) => {
    const candidates = await catalog();
    const settings = await readSettings();
    let selection = settings.textGenerationModelSelection;
    if (!selection || typeof selection.instanceId !== 'string' || typeof selection.model !== 'string') {
      throw new Error('Invalid official text generation setting');
    }
    if (input !== undefined) {
      if (!input || Object.keys(input).length !== 1 || typeof input.model !== 'string' || !candidates.some(m => m.id === input.model)) {
        throw new Error('Choose a visible Pi model');
      }
      // 保留当前模型已有的官方 options；换模型时不能把旧模型的参数误带过去。
      const next = selection.instanceId === 'pi' && selection.model === input.model
        ? selection : { instanceId: 'pi', model: input.model };
      await updateSettings({ textGenerationModelSelection: next });
      selection = (await readSettings()).textGenerationModelSelection;
      if (selection.instanceId !== 'pi' || selection.model !== input.model) throw new Error('Setting update not confirmed');
    } else if (!(selection.instanceId === 'pi' && candidates.some(m => m.id === selection.model)) && candidates.length) {
      // 隐藏/下架当前模型时仅回退到仍显示的 Pi 模型，绝不回退其他 Provider。
      await updateSettings({ textGenerationModelSelection: { instanceId: 'pi', model: candidates[0].id } });
      selection = (await readSettings()).textGenerationModelSelection;
      if (selection.instanceId !== 'pi' || !candidates.some(m => m.id === selection.model)) throw new Error('Fallback update not confirmed');
    }
    const selected = selection.instanceId === 'pi' && candidates.some(m => m.id === selection.model);
    return { status: selected ? 'selected' : 'no-visible-models',
      selection: selected ? selection : null, candidates };
  };
  return { read: () => exclusive(() => snapshot()), set: input => exclusive(() => snapshot(input)) };
}

let titleSettings;
export function configureTitleGenerationSettings(settings) { titleSettings = settings; }
export async function resolveTitleGenerationSelection() {
  if (!titleSettings) throw new Error('Title model settings not ready');
  const snapshot = await titleSettings.read();
  if (!snapshot.selection) {
    // 没有显示的 Pi 模型时，保留官方设置但停止自动标题；不能伪造模型或偷偷调用 Codex。
    throw new Error('Select a visible Pi title model in settings');
  }
  return snapshot.selection;
}
