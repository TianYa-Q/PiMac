import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, writeFile, chmod, readFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createServerGateway } from './fixtures/protocol-server.mjs';
import { call } from '../generated/client.mjs';

test('official title setting persists through private host management, visibility changes and restart', async t => {
  const root = new URL('../../../tmp/', import.meta.url).pathname;
  await mkdir(root, { recursive: true });
  const directory = await mkdtemp(join(root, 'text-generation-management-'));
  const token = 'ef'.repeat(32);
  const binary = join(directory, 'fixture-pi');
  await writeFile(binary, `#!/bin/sh\nexport PIMAC_FIXTURE_EXTRA_MODEL=1\nexec '${process.execPath}' '${new URL('./fixtures/pi.mjs', import.meta.url).pathname}' "$@"\n`);
  await chmod(binary, 0o700);
  let gateway;
  t.after(async () => { await gateway?.close(); });
  const open = async () => {
    gateway = await createServerGateway({ token, directory, piConfig: { binaryPath: binary } });
    await new Promise(resolve => gateway.server.listen(0, '127.0.0.1', resolve));
  };
  await open();
  const setHidden = async models => {
    const { token: credential } = await gateway.official.management.desktopSession();
    const ticketResponse = await fetch(gateway.serverURL + '/api/auth/websocket-ticket', {
      method: 'POST', headers: { authorization: 'Bearer ' + credential, 'content-type': 'application/json', 'x-t3-orchestration-protocol': '2' }, body: '{}',
    });
    assert.equal(ticketResponse.status, 200);
    const { ticket } = await ticketResponse.json();
    await call(gateway.serverURL.replace('http:', 'ws:') + '/ws?orchestrationProtocol=2&wsTicket=' + ticket,
      'server.updateSettings', { patch: { setModelsHidden: models.map(model => ({ provider: 'pi', model, hidden: true })) } });
  };
  const headers = { authorization: `Bearer ${token}`, 'content-type': 'application/json' };
  const url = route => `http://127.0.0.1:${gateway.server.address().port}/internal/auth/${route}`;
  const request = async (route, body) => fetch(url(route), { headers, ...(body ? { method: 'POST', body: JSON.stringify(body) } : {}) });
  const read = async () => { const response = await request('text-generation-model'); assert.equal(response.status, 200); return response.json(); };
  assert.equal((await fetch(url('text-generation-model'))).status, 401);
  assert.equal((await fetch(url('text-generation-model'), { headers: { ...headers, origin: 'https://invalid.test' } })).status, 401);
  await gateway.official.management.textGenerationModel();
  assert.deepEqual((await read()).candidates.map(m => m.id), ['test/model', 'test/alternate']);
  assert.equal((await request('text-generation-model', { model: 'test/alternate' })).status, 200);
  const settingsFile = join(directory, 'server-owned/userdata/settings.json');
  assert.equal(JSON.parse(await readFile(settingsFile, 'utf8')).textGenerationModelSelection.model, 'test/alternate');
  assert.equal(JSON.parse(await readFile(settingsFile, 'utf8')).sourceControlWriterModelSelection.model, 'test/model');
  assert.equal((await request('text-generation-model', { model: 'codex/native' })).status, 400);
  await gateway.close();
  await open();
  assert.equal((await read()).selection.model, 'test/alternate');
  await setHidden(['test/alternate']);
  assert.deepEqual((await read()).selection, { instanceId: 'pi', model: 'test/model' });
  assert.deepEqual((await read()).candidates.map(m => m.id), ['test/model']);
  await setHidden(['test/model']);
  assert.deepEqual(await read(), { status: 'no-visible-models', selection: null, candidates: [] });
  await gateway.close();
  await open();
  assert.deepEqual(await read(), { status: 'no-visible-models', selection: null, candidates: [] });
  const settings = JSON.parse(await readFile(settingsFile, 'utf8'));
  assert.deepEqual(settings.providerModelPreferences.pi.hiddenModels, ['test/alternate', 'test/model']);
  assert.equal((await request('text-generation-model', { model: 'test/model' })).status, 400);
});
