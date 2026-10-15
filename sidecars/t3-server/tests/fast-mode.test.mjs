import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { build, transform } from 'esbuild';
import vm from 'node:vm';
import { plugin } from '../build.mjs';

const patches = JSON.parse(await readFile(new URL('../patches.json', import.meta.url), 'utf8'));
const bundled = await build({ entryPoints: [fileURLToPath(new URL(
  '../upstream/apps/server/src/provider/piThinkingCapabilities.ts', import.meta.url))],
  bundle: true, write: false, platform: 'node', format: 'esm', plugins: [plugin] });
const { thinkingCapabilitiesForPiModel } = await import('data:text/javascript;base64,' +
  Buffer.from(bundled.outputFiles[0].contents).toString('base64'));

test('Fast capabilities follow native provider/API, independently of reasoning or model name', () => {
  for (const provider of ['openai', 'openai-codex']) {
    for (const reasoning of [true, false]) {
      const capabilities = thinkingCapabilitiesForPiModel({ provider, reasoning,
        id: 'gpt-6.1-sol', api: provider === 'openai' ? 'openai-responses' : 'openai-codex-responses' }, 'high');
      const fast = capabilities.optionDescriptors.find(option => option.id === 'fastMode');
      assert.deepEqual(fast.options.map(option => option.id), ['off', 'on']);
      assert.equal(capabilities.optionDescriptors.some(option => option.id === 'thinking'), reasoning);
    }
  }
  for (const model of [null, {}, { provider: 'custom', api: 'openai-responses' },
    { provider: 'openai', api: 'pi-virtual' }, { provider: 'openai', api: 'openai-completions' }]) {
    assert(!thinkingCapabilitiesForPiModel(model, 'high').optionDescriptors.some(option => option.id === 'fastMode'));
  }
});

test('injected runtime extension applies priority only when enabled and rejects invalid or busy changes', async () => {
  // 直接执行构建注入的扩展函数；不能只测已不由新 Server 加载的旧资源文件。
  const patch = patches['apps/server/src/orchestration-v2/Adapters/piT3McpExtensionSource.ts'][0];
  const compiled = await transform(patch.newText + '\n}', { loader: 'ts', format: 'esm' });
  const { default: factory } = await import('data:text/javascript;base64,' + Buffer.from(compiled.code).toString('base64'));
  const previous = process.env.PIMAC_FAST_MODE;
  process.env.PIMAC_FAST_MODE = '0';
  try {
    const events = new Map(), commands = new Map(), statuses = [];
    await factory({ on: (name, handler) => events.set(name, handler),
      registerCommand: (name, command) => commands.set(name, command) });
    const ctx = { model: { provider: 'openai-codex', api: 'openai-codex-responses' },
      isIdle: () => true, ui: { setStatus: (...args) => statuses.push(args) } };
    const payload = { model: 'gpt-6.1-sol', input: [] };
    const request = () => events.get('before_provider_request')({ payload }, ctx);
    assert.equal(request(), undefined);
    await commands.get('pimac-fast').handler('on', ctx);
    assert.deepEqual(statuses.at(-1), ['pimac-fast', 'on']);
    assert.equal(request().service_tier, 'priority');
    assert.equal(payload.service_tier, undefined);
    await assert.rejects(commands.get('pimac-fast').handler('invalid', ctx));
    await assert.rejects(commands.get('pimac-fast').handler('off', { ...ctx, isIdle: () => false }));
    for (const model of [{ provider: 'custom', api: 'openai-responses' },
      { provider: 'openai-codex', api: 'pi-virtual' }, undefined]) {
      assert.equal(events.get('before_provider_request')({ payload }, { ...ctx, model }), undefined);
    }
    await commands.get('pimac-fast').handler('off', ctx);
    assert.equal(request(), undefined);
  } finally {
    if (previous === undefined) delete process.env.PIMAC_FAST_MODE;
    else process.env.PIMAC_FAST_MODE = previous;
  }
});

test('adapter fails closed before prompting when Fast is unsupported, missing or unconfirmed', () => {
  const patch = patches['apps/server/src/orchestration-v2/Adapters/PiAdapterV2.ts']
    .find(patch => patch.newText.includes('const fast ='));
  const body = patch.newText.slice(0, patch.newText.lastIndexOf('        if ('));
  function run({ commands, model, confirmed, fast = 'on', initialStatus }) {
    const sent = [];
    const scope = { fastStatus: initialStatus,
      getModelSelectionStringOptionValue: () => fast,
      recordField: (value, key) => value?.[key], recordString: (value, key) => value?.[key],
      protocolError: function* (message) { throw new Error(message); },
      Effect: { sleep: function* () {} },
      request: function* (command) {
        sent.push(command);
        if (command.type === 'get_commands') return { commands };
        if (command.type === 'get_state') return { model };
        if (confirmed) scope.fastStatus = fast;
        return { disposition: 'handled' };
      } };
    const execute = vm.runInNewContext('(function* (modelSelection) {' + body + '})', scope);
    return { sent, execute: () => execute({}).next() };
  }
  const commands = [{ name: 'pimac-fast', source: 'extension' }];
  const model = { provider: 'openai-codex', api: 'openai-codex-responses' };
  for (const bad of [[], [{ name: 'pimac-fast', source: 'prompt' }]]) {
    const result = run({ commands: bad, model });
    assert.throws(result.execute, /extension unavailable/);
    assert(!result.sent.some(command => command.type === 'prompt'));
  }
  const unsupported = run({ commands, model: { provider: 'openai-codex', api: 'pi-virtual' } });
  assert.throws(unsupported.execute, /does not support/);
  assert(!unsupported.sent.some(command => command.type === 'prompt'));
  assert.throws(run({ commands, model }).execute, /not confirmed/);
  for (const fast of ['on', 'off']) {
    const result = run({ commands, model, confirmed: true, fast, initialStatus: 'on' });
    assert.equal(result.execute().done, true);
    assert.equal(result.sent.at(-1).message, '/pimac-fast ' + fast);
  }
});
