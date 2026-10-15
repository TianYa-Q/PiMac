import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { browserAuthorization, configureNative } from '../native.mjs';

test('desktop only captures its active T3 login; other URLs use the official browser launcher', async t => {
  const broker = configureNative({ environmentId: 'browser-fixture' });
  t.after(() => broker.close());
  assert.equal(browserAuthorization('https://app.t3.codes/connect?state=fixture'), false);
  const captured = [];
  broker.onBrowser = url => captured.push(url);
  for (const url of ['https://provider.example/oauth/authorize', 'https://example.com/',
    'https://app.t3.codes/settings', 'not a URL']) {
    assert.equal(browserAuthorization(url), false);
  }
  const login = 'https://app.t3.codes/connect?state=fixture';
  assert.equal(browserAuthorization(login), true);
  assert.deepEqual(captured, [login]);
  assert.equal(broker.browserURL, login);
  // 同时约束实际注入点，避免辅助函数允许后启动器仍被无条件替换。
  const patches = JSON.parse(await readFile(new URL('../patches.json', import.meta.url), 'utf8'));
  assert(patches['apps/server/src/process/externalLauncher.ts'].some(patch =>
    patch.newText.includes('PiNative.browserAuthorization(target) ? Effect.void : launchBrowser(target)')));
});
