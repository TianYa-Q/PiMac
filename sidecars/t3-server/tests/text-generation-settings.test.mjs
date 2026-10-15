import test from 'node:test';
import assert from 'node:assert/strict';
import { createTextGenerationSettings, configureTitleGenerationSettings, resolveTitleGenerationSelection } from '../text-generation-settings.mjs';

function fixture(selection = { instanceId: 'codex', model: 'gpt-5.4-mini' }) {
  let settings = { textGenerationModelSelection: selection, other: { preserved: true } };
  let models = [{ slug: 'anthropic/sonnet', name: 'Sonnet' }, { slug: 'openai/gpt', name: 'GPT' }];
  let hidden = new Set();
  let failure = false;
  let health = {};
  const writes = [];
  const controller = createTextGenerationSettings({
    readSettings: async () => structuredClone(settings),
    updateSettings: async patch => { if (failure) throw new Error('write failed'); writes.push(patch); settings = { ...settings, ...patch }; },
    readProviders: async () => [{ instanceId: 'pi', driver: 'pi', enabled: true, models, ...health },
      { instanceId: 'codex', driver: 'codex', models: [{ slug: 'native', name: 'Native' }] }],
    visibleProviders: providers => providers.map(p => ({ ...p, models: p.models.filter(m => !hidden.has(m.slug)) })),
  });
  return { controller, writes, settings: () => settings,
    hide: ids => { hidden = new Set(ids); }, catalog: value => { models = value; },
    health: value => { health = value; }, fail: () => { failure = true; } };
}

test('official setting only; preserve explicit visible Pi selection/options and other settings', async () => {
  const f = fixture({ instanceId: 'pi', model: 'openai/gpt', options: [{ id: 'thinking', value: 'low' }] });
  assert.equal((await f.controller.read()).selection.model, 'openai/gpt');
  assert.equal(f.writes.length, 0);
  await f.controller.set({ model: 'anthropic/sonnet' });
  assert.deepEqual(f.settings(), { textGenerationModelSelection: { instanceId: 'pi', model: 'anthropic/sonnet' }, other: { preserved: true } });
  assert.equal((await f.controller.read()).selection.model, 'anthropic/sonnet');
  assert.equal(f.writes.length, 1); // 再读/重连不能重置显式选择。
});
test('initial Codex, hidden current and disappeared catalog fallback only to visible Pi', async () => {
  const f = fixture();
  assert.equal((await f.controller.read()).selection.model, 'anthropic/sonnet');
  f.hide(['anthropic/sonnet']);
  const next = await f.controller.read();
  assert.deepEqual(next.candidates.map(m => m.id), ['openai/gpt']);
  assert.equal(next.selection.model, 'openai/gpt');
  f.catalog([{ slug: 'google/flash', name: 'Flash' }]);
  assert.equal((await f.controller.read()).selection.model, 'google/flash');
});
test('all hidden is explicit pending; title guard blocks background fallback; restore recovers', async () => {
  const f = fixture();
  f.hide(['anthropic/sonnet', 'openai/gpt']);
  const pending = await f.controller.read();
  assert.deepEqual(pending, { status: 'no-visible-models', selection: null, candidates: [] });
  assert.equal(f.writes.length, 0); // 非 nullable 的官方字段不写假模型或 null。
  configureTitleGenerationSettings(f.controller);
  await assert.rejects(resolveTitleGenerationSelection(), /Select a visible Pi/);
  f.hide([]);
  await f.controller.read();
  assert.deepEqual(await resolveTitleGenerationSelection(), { instanceId: 'pi', model: 'anthropic/sonnet' });
});
test('reject hidden/unknown/empty/malformed updates and propagate official update errors', async () => {
  const f = fixture(); f.hide(['anthropic/sonnet']);
  for (const input of [{ model: '' }, { model: 'missing' }, { model: 'anthropic/sonnet' }, {}, null, { model: 'openai/gpt', extra: true }]) {
    await assert.rejects(f.controller.set(input), /Choose a visible Pi/);
  }
  assert.equal(f.writes.length, 0);
  f.fail();
  await assert.rejects(f.controller.set({ model: 'openai/gpt' }), /write failed/);
  assert.equal(f.settings().textGenerationModelSelection.instanceId, 'codex');
  await assert.rejects(f.controller.read(), /write failed/);
});
test('catalog corruption/discovery failure is not empty; default sentinel never becomes fallback', async () => {
  const f = fixture();
  f.health({ status: 'warning', auth: { status: 'unknown' } });
  await assert.rejects(f.controller.read(), /discovery is unavailable/);
  assert.equal(f.writes.length, 0);
  f.health({});
  f.catalog([{ slug: 'default', name: 'Pi default' }, { slug: 'test/real', name: 'Real' }]);
  assert.deepEqual((await f.controller.read()).candidates.map(m => m.id), ['test/real']);
  f.catalog([{ name: 'Broken' }]);
  await assert.rejects(f.controller.read(), /Invalid Pi model catalog/);
  f.catalog([]);
  assert.equal((await f.controller.read()).status, 'no-visible-models');
});
