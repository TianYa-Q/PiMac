import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configureModelPreferences, setModelPreferences } from '../model-preferences.mjs';

test('desktop model preferences are private and no longer override Pi compaction configuration', t => {
  const directory = mkdtempSync(join(tmpdir(), 'pimac-model-preferences-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  configureModelPreferences(directory);
  setModelPreferences({ hiddenModels: ['test/hidden', 'test/hidden'], defaultModel: 'test/model', compactionModel: 'obsolete/model' });
  assert.deepEqual(JSON.parse(readFileSync(join(directory, 'model-preferences.json'), 'utf8')), {
    hiddenModels: ['test/hidden'], defaultModel: 'test/model',
  });
  assert.throws(() => setModelPreferences({ hiddenModels: [42], defaultModel: null }), /Invalid/);
});
