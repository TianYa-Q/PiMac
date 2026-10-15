import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { createTextGenerationSettings } from '../text-generation-settings.mjs';
import { configureModelPreferences, setModelPreferences, syncModelPreferences, visibleProviders, subscribeModelPreferences } from '../model-preferences.mjs';

test('visibility sync is independent of title discovery, but preference write failures still reject', async t => {
  const root = new URL('../../../tmp/', import.meta.url).pathname;
  mkdirSync(root, { recursive: true });
  const directory = mkdtempSync(join(root, 'preferences-failure-'));
  t.after(() => execFileSync('trash', [directory]));
  configureModelPreferences(directory);
  const title = createTextGenerationSettings({
    readSettings: async () => { throw new Error('title settings unavailable'); },
    updateSettings: async () => { throw new Error('title update unavailable'); },
    readProviders: async () => { throw new Error('transient Pi catalog error'); }, visibleProviders,
  });
  const value = { hiddenModels: ['test/hidden'], defaultModel: 'test/visible' };
  let written;
  assert.deepEqual(await syncModelPreferences(value, async patch => { written = patch; }), { ok: true });
  assert.deepEqual(written, { defaultModelSelection: { instanceId: 'pi', model: 'test/visible' } });
  assert.deepEqual(JSON.parse(readFileSync(join(directory, 'model-preferences.json'), 'utf8')), value);
  await assert.rejects(title.read(), /transient Pi catalog error/);
  await assert.rejects(title.set({ model: 'test/visible' }), /transient Pi catalog error/);
  await assert.rejects(syncModelPreferences(value, async () => { throw new Error('official write failed'); }), /official write failed/);
  mkdirSync(join(directory, 'model-preferences.json.tmp'));
  let called = false;
  await assert.rejects(syncModelPreferences(value, async () => { called = true; }), /EISDIR/);
  assert.equal(called, false);
});

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
  const disabled = { driver: 'claudeAgent', enabled: false, models: [] };
  const enabled = { driver: 'claudeAgent', enabled: true, models: [] };
  assert.deepEqual(visibleProviders([...providers, disabled, enabled]).map(p => p.driver), ['pi', 'pi', 'codex', 'claudeAgent']);
  assert.equal(disabled.enabled, false); // Presentation never mutates settings/runtime.
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
