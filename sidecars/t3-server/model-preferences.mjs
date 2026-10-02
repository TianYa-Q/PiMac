import fs from 'node:fs';
import path from 'node:path';

// Desktop preferences only. Pi discovery and the shared provider catalog are
// official and unfiltered; mobile clients own their visibility preferences.
let file;
export function configureModelPreferences(directory) {
  file = path.join(directory, 'model-preferences.json');
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
}
