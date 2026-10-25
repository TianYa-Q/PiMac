import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';
import { migrateModelPreferences, visibleProviders } from '../model-preferences.mjs';

test('visibility follows official per-instance preferences without changing runtime catalogs', () => {
  const models = [{ slug: 'test/hidden' }, { slug: 'test/model' }];
  const providers = [
    { driver: 'pi', instanceId: 'pi', models },
    { driver: 'pi', instanceId: 'work', models },
    { driver: 'codex', instanceId: 'codex', models },
    { driver: 'claudeAgent', instanceId: 'disabled', enabled: false, models },
  ];
  const settings = { providerModelPreferences: {
    pi: { hiddenModels: ['test/hidden'], modelOrder: ['test/model'] },
    codex: { hiddenModels: ['test/model'], modelOrder: [] },
  } };
  assert.deepEqual(visibleProviders(providers, settings).map(p => p.models.map(m => m.slug)), [
    ['test/model'], ['test/hidden', 'test/model'], ['test/hidden'],
  ]);
  assert.equal(providers[0].models.length, 2);
  assert.equal(visibleProviders(providers, { providerModelPreferences: null })[0].models.length, 2);
});

test('legacy migration uses the official write-once patch and does not conceal invalid data or failures', async t => {
  const root = new URL('../../../tmp/', import.meta.url).pathname;
  mkdirSync(root, { recursive: true });
  const directory = mkdtempSync(join(root, 'model-preferences-'));
  t.after(() => execFileSync('trash', [directory]));
  let patch;
  await migrateModelPreferences(directory, async value => { patch = value; });
  assert.equal(patch, undefined);
  const file = join(directory, 'model-preferences.json');
  writeFileSync(file, JSON.stringify({ hiddenModels: ['test/hidden', 'test/hidden'], defaultModel: null }));
  await migrateModelPreferences(directory, async value => { patch = value; });
  assert.deepEqual(patch, { migrateModelPreferences: { providerModelPreferences: {
    pi: { hiddenModels: ['test/hidden'], modelOrder: [] },
  } } });
  await assert.rejects(migrateModelPreferences(directory, async () => { throw new Error('official write failed'); }), /official write failed/);
  writeFileSync(file, '{');
  await assert.rejects(migrateModelPreferences(directory, async () => {}), SyntaxError);
  writeFileSync(file, JSON.stringify({ hiddenModels: [42] }));
  await assert.rejects(migrateModelPreferences(directory, async () => {}), /Invalid legacy/);
});
