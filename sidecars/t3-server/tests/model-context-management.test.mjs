import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile, chmod, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';

// 用隔离的 Pi agent 目录验证真正的桌面管理端点，绝不写入用户 models.json。
test('desktop context settings are persisted through authenticated local administration only', async t => {
  const root = new URL('../../../tmp/', import.meta.url).pathname;
  await mkdir(root, { recursive: true });
  const directory = await mkdtemp(join(root, 'model-context-management-'));
  const agentDirectory = join(directory, 'agent');
  const previous = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = agentDirectory;
  const token = 'cd'.repeat(32);
  const binary = join(directory, 'fixture-pi');
  await writeFile(binary, `#!/bin/sh\nexec '${process.execPath}' '${new URL('./fixtures/pi.mjs', import.meta.url).pathname}' "$@"\n`);
  await chmod(binary, 0o700);
  let gateway;
  t.after(async () => {
    await gateway?.close();
    if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previous;
  });
  gateway = await createServerGateway({ token, directory, piConfig: { binaryPath: binary } });
  await new Promise(resolve => gateway.server.listen(0, '127.0.0.1', resolve));
  const url = `http://127.0.0.1:${gateway.server.address().port}/internal/auth/model-context`;
  const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  assert.equal((await fetch(url)).status, 401);
  assert.equal((await fetch(url, { headers: { ...headers, origin: 'http://evil.invalid' } })).status, 401);
  await gateway.official.management.modelCatalog();
  assert.deepEqual(await (await fetch(url, { headers })).json(), { overrides: {}, defaults: { 'test/model': 10000 } });
  let response = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ modelId: 'test/model', tokens: 1050000 }) });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { overrides: { 'test/model': 1050000 }, defaults: { 'test/model': 10000 } });
  const file = join(agentDirectory, 'models.json');
  const saved = await readFile(file, 'utf8');
  assert.equal(JSON.parse(saved).providers.test.modelOverrides.model.contextWindow, 1050000);
  response = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ modelId: 'test/model', tokens: -1 }) });
  assert.equal(response.status, 400);
  assert.equal(await readFile(file, 'utf8'), saved);
  // 在覆盖存在时重新发现，不能将 Pi 返回的有效额度冒充基础默认值。
  await gateway.official.management.modelCatalog();
  assert.deepEqual(await (await fetch(url, { headers })).json(), { overrides: { 'test/model': 1050000 }, defaults: {} });
  response = await fetch(url, { method: 'POST', headers, body: JSON.stringify({ modelId: 'test/model', tokens: null }) });
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { overrides: {}, defaults: {} });
  await gateway.official.management.modelCatalog();
  assert.deepEqual(await (await fetch(url, { headers })).json(), { overrides: {}, defaults: { 'test/model': 10000 } });
});
