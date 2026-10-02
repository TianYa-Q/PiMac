import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';

test('private controls switch accounts and compact without creating a chat turn; Fast survives resume', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-controls-'));
  let gateway;
  const open = async () => {
    gateway = await createServerGateway({ token: 'ab'.repeat(32), directory,
      piConfig: { binaryPath: process.execPath, binaryArgs: [new URL('./fixtures/pi.mjs', import.meta.url).pathname] } });
    return (await gateway.official.management.desktopSession()).token;
  };
  t.after(async () => { await gateway?.close(); await rm(directory, { recursive: true, force: true }); });
  let token = await open();
  const request = async (path, body) => {
    const response = await fetch(gateway.serverURL + path, { method: body ? 'POST' : 'GET',
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
    assert.equal(response.status, 200); return response.json();
  };
  const dispatch = body => request('/api/orchestration/dispatch', { commandId: randomUUID(), createdAt: new Date().toISOString(), ...body });
  const projectId = randomUUID(), threadId = randomUUID();
  await dispatch({ type: 'project.create', projectId, title: 'Controls', workspaceRoot: directory });
  await dispatch({ type: 'thread.create', projectId, threadId, title: 'Controls', modelSelection: { instanceId: 'pi', model: 'openai/model', options: [{ id: 'fastMode', value: 'on' }] }, runtimeMode: 'full-access', interactionMode: 'default', branch: null, worktreePath: null });
  const controls = input => gateway.official.management.sessionControl({ threadId, ...input });
  await assert.rejects(controls({ operation: 'arbitrary-command' }));
  await assert.rejects(controls({ operation: 'switch-account', accountName: 'bad name' }));
  await controls({ operation: 'switch-account', accountName: 'second' });
  const status = await gateway.official.management.accountStatus(threadId, 'openai');
  assert.equal(JSON.parse(status.status).activeAccount, 'second');
  await controls({ operation: 'compact' });
  const snapshot = await request('/api/orchestration/threads/' + threadId);
  assert.equal(snapshot.thread.messages.length, 0);
  const root = join(directory, 'server-owned/pi-sessions');
  const records = async () => {
    const lines = [];
    for (const instance of await readdir(root)) for (const file of await readdir(join(root, instance))) lines.push(...(await readFile(join(root, instance, file), 'utf8')).trim().split('\n').map(JSON.parse));
    return lines;
  };
  assert((await records()).some(r => r.message === '/pimac-fast on'));
  await gateway.close(); token = await open();
  await controls({ operation: 'compact' });
  assert.equal((await records()).filter(r => r.message === '/pimac-fast on').length, 2);
  await dispatch({ type: 'thread.turn.start', threadId, runtimeMode: 'full-access', interactionMode: 'default', message: { messageId: randomUUID(), role: 'user', text: 'wait', attachments: [] } });
  await new Promise(resolve => setTimeout(resolve, 150));
  await assert.rejects(controls({ operation: 'compact' }));
  await assert.rejects(controls({ operation: 'switch-account', accountName: 'first' }));
});
