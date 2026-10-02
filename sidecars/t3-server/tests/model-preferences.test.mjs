import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configureModelPreferences, setModelPreferences, visibleModels, modelPreferencesKey } from '../model-preferences.mjs';

const models = [{ provider: 'one', id: 'a' }, { provider: 'two', id: 'a' }, { provider: 'one', id: 'b' }];
test('mobile catalog uses desktop visibility and explicit default, not discovery current model', () => {
  setModelPreferences({ hiddenModels: ['one/a'], defaultModel: 'one/b' });
  const result = visibleModels(models, 'two/a');
  assert.deepEqual(result.map(m => `${m.provider}/${m.id}`), ['one/b', 'two/a']);
  assert.deepEqual(result.map(m => m.isDefault), [true, false]);
  assert.equal(models.length, 3);
});
test('hidden or unavailable defaults fall back to visible current, then first visible model', () => {
  setModelPreferences({ hiddenModels: ['one/a'], defaultModel: 'one/a' });
  assert.equal(visibleModels(models, 'two/a')[0].provider, 'two');
  assert.equal(visibleModels(models, 'one/a')[0].provider, 'two');
  setModelPreferences({ hiddenModels: models.map(m => `${m.provider}/${m.id}`), defaultModel: null });
  assert.deepEqual(visibleModels(models, 'one/a'), []);
});
test('preferences survive server restart and changes invalidate the catalog cache key', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pimac-models-'));
  try {
    configureModelPreferences(directory);
    const initial = modelPreferencesKey();
    setModelPreferences({ hiddenModels: ['one/a'], defaultModel: 'one/b' });
    const updated = modelPreferencesKey();
    assert.notEqual(updated, initial);
    configureModelPreferences(directory);
    assert.equal(modelPreferencesKey(), updated);
    assert.throws(() => setModelPreferences({ hiddenModels: [1], defaultModel: null }));
    assert.equal(modelPreferencesKey(), updated);
  } finally { rmSync(directory, { recursive: true, force: true }); configureModelPreferences(directory); }
});
