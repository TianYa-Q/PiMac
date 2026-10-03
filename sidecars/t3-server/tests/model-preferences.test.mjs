import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configureModelPreferences, setModelPreferences, visibleProviders, subscribeModelPreferences } from '../model-preferences.mjs';

test('shared model preferences are private and do not override Pi compaction configuration', t => {
  const directory = mkdtempSync(join(tmpdir(), 'pimac-model-preferences-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  configureModelPreferences(directory);
  setModelPreferences({ hiddenModels: ['test/hidden', 'test/hidden'], defaultModel: 'test/model', compactionModel: 'obsolete/model' });
  assert.deepEqual(JSON.parse(readFileSync(join(directory, 'model-preferences.json'), 'utf8')), {
    hiddenModels: ['test/hidden'], defaultModel: 'test/model',
  });
  assert.throws(() => setModelPreferences({ hiddenModels: [42], defaultModel: null }), /Invalid/);
  const providers = [{ driver: 'pi', instanceId: 'personal', models: [{ slug: 'test/hidden' }, { slug: 'test/model' }] },
    { driver: 'pi', instanceId: 'work', models: [{ slug: 'test/hidden' }] },
    { driver: 'codex', models: [{ slug: 'test/hidden' }] }];
  assert.deepEqual(visibleProviders(providers).map(p => p.models.length), [1, 0, 1]);
  assert.equal(providers[0].models.length, 2); // Runtime catalog stays intact.
  configureModelPreferences(directory); // Persisted visibility survives restart.
  assert.equal(visibleProviders(providers)[0].models.length, 1);
  let updates = 0;
  const unsubscribe = subscribeModelPreferences(() => updates++);
  setModelPreferences({ hiddenModels: [], defaultModel: null });
  assert.equal(updates, 2);
  assert.equal(visibleProviders(providers)[0].models.length, 2);
  unsubscribe();
  setModelPreferences({ hiddenModels: ['test/hidden'], defaultModel: null });
  assert.equal(updates, 2);
});
