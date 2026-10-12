import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, statSync, symlinkSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { createModelContextSettings } from '../model-context.mjs';

// 测试文件保留在 checkout/tmp，避免触碰真实 Pi 配置和模型缓存。
const root = new URL('../../../tmp/', import.meta.url).pathname;
mkdirSync(root, { recursive: true });
function fixture() {
  const directory = mkdtempSync(join(root, 'model-context-'));
  const file = join(directory, 'models.json');
  return { file, store: createModelContextSettings(directory) };
}

test('missing configuration is an empty state; a saved override survives a new reader', () => {
  const { file, store } = fixture();
  assert.deepEqual(store.snapshot(), { overrides: {}, defaults: {} });
  assert.deepEqual(store.set({ modelId: 'openai-codex/gpt-6.1-sol', tokens: 1_050_000 }), {
    overrides: { 'openai-codex/gpt-6.1-sol': 1_050_000 }, defaults: {},
  });
  assert.equal(statSync(file).mode & 0o777, 0o600);
  assert.deepEqual(createModelContextSettings(dirname(file)).snapshot(), store.snapshot());
  assert.deepEqual(store.set({ modelId: 'openai-codex/gpt-6.1-sol', tokens: null }), { overrides: {}, defaults: {} });
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), { providers: {} });
});

test('patch and reset preserve credentials, custom model definitions and unrelated overrides', () => {
  const { file, store } = fixture();
  const original = { extra: { retained: true }, providers: {
    custom: { baseUrl: 'https://example.invalid/v1', apiKey: '$TEST_KEY',
      models: [{ id: 'nested/model', contextWindow: 200000, maxTokens: 10000 }],
      modelOverrides: { 'nested/model': { contextWindow: 250000, reasoning: true },
        other: { contextWindow: 123456, name: 'Other' } } },
  } };
  writeFileSync(file, JSON.stringify(original));
  store.set({ modelId: 'custom/nested/model', tokens: 1_000_000 });
  const updated = JSON.parse(readFileSync(file, 'utf8'));
  original.providers.custom.modelOverrides['nested/model'].contextWindow = 1_000_000;
  assert.deepEqual(updated, original);
  // 模拟用户在两次保存间编辑文件，写入必须保留这次外部修改。
  updated.providers.custom.headers = { 'X-Test': 'retained' };
  writeFileSync(file, JSON.stringify(updated));
  store.set({ modelId: 'custom/nested/model', tokens: null });
  delete updated.providers.custom.modelOverrides['nested/model'].contextWindow;
  assert.deepEqual(JSON.parse(readFileSync(file, 'utf8')), updated);
  assert.equal(store.snapshot().overrides['custom/nested/model'], undefined);
  assert.equal(updated.providers.custom.models[0].contextWindow, 200000);
});

test('invalid input and damaged configuration never overwrite the existing file', () => {
  const { file, store } = fixture();
  writeFileSync(file, '{"providers":{}}');
  for (const tokens of [0, -1, 1.5, '1000', true, Number.MAX_SAFE_INTEGER + 1, undefined]) {
    assert.throws(() => store.set({ modelId: 'test/model', tokens }), /Invalid/);
    assert.equal(readFileSync(file, 'utf8'), '{"providers":{}}');
  }
  for (const modelId of ['test', '/model', 'test/', '__proto__/model', 'test/constructor', ' test/model', 'test/\nmodel']) {
    assert.throws(() => store.set({ modelId, tokens: 1000 }), /Invalid/);
  }
  for (const content of ['{broken', '[]', '{"providers":[]}', '{"providers":{"test":null}}',
    '{"providers":{"test":{"modelOverrides":[]}}}',
    '{"providers":{"test":{"modelOverrides":{"model":{"contextWindow":false}}}}}']) {
    writeFileSync(file, content);
    assert.throws(() => store.snapshot());
    assert.throws(() => store.set({ modelId: 'test/model', tokens: 1000 }));
    assert.equal(readFileSync(file, 'utf8'), content);
  }
});

test('symlink targets cannot be replaced and valid Object prototype names remain ordinary keys', () => {
  const { file, store } = fixture();
  const target = file + '.target';
  writeFileSync(target, '{"providers":{}}');
  symlinkSync(target, file);
  assert.throws(() => store.set({ modelId: 'test/model', tokens: 1000 }));
  assert.equal(readFileSync(target, 'utf8'), '{"providers":{}}');
  const other = fixture().store;
  assert.deepEqual(other.set({ modelId: 'toString/toString', tokens: 1000 }), {
    overrides: { 'toString/toString': 1000 }, defaults: {},
  });
});


test('Pi discovery supplies exact defaults and never labels an overridden window as default', () => {
  const { store } = fixture();
  store.recordModels({ models: [
    { provider: 'openai-codex', id: 'gpt-6.1-sol', contextWindow: 272000 },
    { provider: 'test', id: 'missing' },
  ] });
  assert.deepEqual(store.snapshot(), { overrides: {}, defaults: { 'openai-codex/gpt-6.1-sol': 272000 } });
  store.set({ modelId: 'openai-codex/gpt-6.1-sol', tokens: 1050000 });
  store.recordModels({ models: [{ provider: 'openai-codex', id: 'gpt-6.1-sol', contextWindow: 1050000 }] });
  assert.deepEqual(store.snapshot(), { overrides: { 'openai-codex/gpt-6.1-sol': 1050000 }, defaults: {} });
  store.set({ modelId: 'openai-codex/gpt-6.1-sol', tokens: null });
  assert.deepEqual(store.snapshot(), { overrides: {}, defaults: {} }); // Reset must not reuse overridden metadata.
  store.recordModels({ models: [{ provider: 'openai-codex', id: 'gpt-6.1-sol', contextWindow: 1000000 }] });
  assert.deepEqual(store.snapshot(), { overrides: {}, defaults: { 'openai-codex/gpt-6.1-sol': 1000000 } });
  store.recordModels({ models: [] });
  assert.deepEqual(store.snapshot(), { overrides: {}, defaults: {} }); // Removed models cannot retain stale defaults.
});

test('invalid discovery keeps the last valid snapshot and cannot leak between agent directories', () => {
  const { store } = fixture();
  store.recordModels({ models: [{ provider: 'test', id: 'model', contextWindow: 10000 }] });
  for (const data of [null, {}, { models: false }, { models: [{ provider: 'test', id: 'model', contextWindow: -1 }] }]) {
    assert.throws(() => store.recordModels(data), /Invalid Pi/);
    assert.deepEqual(store.snapshot().defaults, { 'test/model': 10000 });
  }
  assert.deepEqual(fixture().store.snapshot().defaults, {});
});
