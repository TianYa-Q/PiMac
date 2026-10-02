import fs from 'node:fs';
import path from 'node:path';

let file;
const catalogs = new Map();
export function recordModelCatalog(instanceId, models) { catalogs.set(instanceId, models); }
export function nativeModelCatalog() { return Object.fromEntries(catalogs); }
let preferences = { hiddenModels: [], defaultModel: null };
export function configureModelPreferences(directory) {
  catalogs.clear();
  file = path.join(directory, 'model-preferences.json');
  preferences = { hiddenModels: [], defaultModel: null };
  try { preferences = validate(JSON.parse(fs.readFileSync(file, 'utf8'))); } catch {}
}
function validate(value) {
  if (!value || !Array.isArray(value.hiddenModels) || !value.hiddenModels.every(id => typeof id === 'string') ||
      !(value.defaultModel === null || typeof value.defaultModel === 'string')) throw new Error('Invalid model preferences');
  return { hiddenModels: [...new Set(value.hiddenModels)], defaultModel: value.defaultModel };
}
export function setModelPreferences(value) {
  const next = validate(value);
  if (file) {
    const temporary = file + '.tmp';
    fs.writeFileSync(temporary, JSON.stringify(next), { mode: 0o600 });
    fs.renameSync(temporary, file);
  }
  preferences = next;
}
export function modelPreferencesKey() { return JSON.stringify(preferences); }
export function visibleModels(models, current) {
  const hidden = new Set(preferences.hiddenModels);
  const visible = models.filter(m => !hidden.has(`${m.provider}/${m.id}`));
  const preferred = visible.find(m => `${m.provider}/${m.id}` === preferences.defaultModel)
    ?? visible.find(m => `${m.provider}/${m.id}` === current) ?? visible[0];
  return visible.map(m => ({ ...m, isDefault: m === preferred })).sort((a, b) => Number(b.isDefault) - Number(a.isDefault));
}
