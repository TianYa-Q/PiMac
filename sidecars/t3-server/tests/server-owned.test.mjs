import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';
import { call } from '../generated/client.mjs';
const token = 'ab'.repeat(32);
const piConfig = { binaryPath: process.execPath, binaryArgs: [new URL('./fixtures/pi.mjs', import.meta.url).pathname] };
const grants = { grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
  subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap', requested_token_type: 'urn:ietf:params:oauth:token-type:access_token' };
const delay = ms => new Promise(r => setTimeout(r, ms));
async function eventually(fn) {
  for (let n = 0; n < 100; n++) { const value = await fn(); if (value) return value; await delay(50); }
  throw new Error('Timed out waiting for server projection');
}
async function open(directory) {
  const gateway = await createServerGateway({ token, directory, piConfig });
  await new Promise(r => gateway.server.listen(0, '127.0.0.1', r));
  const base = gateway.serverURL;
  assert.equal((await fetch(base + '/api/orchestration/shell')).status, 401);
  const privateURL = `http://127.0.0.1:${gateway.server.address().port}`;
  assert.equal((await fetch(privateURL + '/internal/request', { method: 'POST',
    headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
    body: JSON.stringify({ method: 'session.prompt' }) })).status, 404);
  const pairing = await gateway.official.management.pairing({ label: 'Migration test' });
  const response = await fetch(base + '/oauth/token', { method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ ...grants, subject_token: pairing.credential }) });
  const auth = await response.json(); assert.equal(response.status, 200);
  const headers = { authorization: 'Bearer ' + auth.access_token, 'content-type': 'application/json' };
  const get = async pathname => {
    const response = await fetch(base + pathname, { headers }); assert.equal(response.status, 200); return response.json();
  };
  const ws = async () => {
    const response = await fetch(base + '/api/auth/websocket-ticket', { method: 'POST', headers, body: '{}' });
    const ticket = await response.json(); assert.equal(response.status, 200);
    return base.replace('http:', 'ws:') + '/ws?orchestrationProtocol=1&wsTicket=' + ticket.ticket;
  };
  const dispatch = async command => {
    const response = await fetch(base + '/api/orchestration/dispatch', { method: 'POST', headers, body: JSON.stringify(command) });
    const body = await response.json(); assert.equal(response.status, 200, JSON.stringify(body)); return body;
  };
  return { gateway, get, ws, dispatch, close: () => gateway.close() };
}
async function sessionFiles(directory) {
  const root = join(directory, 'server-owned/pi-sessions');
  const instances = await readdir(root).catch(() => []);
  const files = [];
  for (const instance of instances) for (const file of await readdir(join(root, instance))) files.push(join(root, instance, file));
  return files;
}

test('desktop model preferences reach mobile config and server default selection', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-model-sync-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const update = async body => {
    const response = await fetch(`http://127.0.0.1:${f.gateway.server.address().port}/internal/auth/model-preferences`, {
      method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' }, body: JSON.stringify(body),
    });
    assert.equal(response.status, 200);
  };
  await update({ hiddenModels: [], defaultModel: 'test/model' });
  let config = await call(await f.ws(), 'server.getConfig');
  assert.equal(config.providers[0].models[0].isDefault, true);
  assert.deepEqual(config.settings.defaultModelSelection, { instanceId: 'pi', model: 'test/model' });
  await update({ hiddenModels: ['test/model'], defaultModel: 'test/model' });
  config = await call(await f.ws(), 'server.getConfig');
  assert.deepEqual(config.providers[0].models, []);
  assert.equal(config.settings.defaultModelSelection, null);
  const native = await f.gateway.official.management.modelCatalog();
  assert.equal(JSON.parse(native.catalogs).pi[0].slug, 'test/model');
});

test('T3 owns projects, turns, native receipts and projections without any desktop IPC', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-server-owned-'));
  let f;
  t.after(async () => { await f?.close(); await rm(directory, { recursive: true, force: true }); });
  f = await open(directory);
  assert.equal((await f.get('/api/orchestration/shell')).threads.length, 0);
  assert.equal((await f.get('/api/orchestration/shell')).projects.length, 0);
  const config = await call(await f.ws(), 'server.getConfig');
  assert.equal(config.providers[0].driver, 'pi');
  assert.equal(config.providers[0].models[0].slug, 'test/model');
  const projectId = randomUUID(), threadId = randomUUID(), createdAt = new Date().toISOString();
  await f.dispatch({ type: 'project.create', commandId: randomUUID(), projectId, title: 'Server Project', workspaceRoot: directory, createdAt });
  const selection = { instanceId: 'pi', model: 'test/model' };
  await call(await f.ws(), 'orchestration.dispatchCommand', { type: 'thread.create', commandId: randomUUID(), projectId, threadId,
    title: 'Server Thread', modelSelection: selection, runtimeMode: 'full-access', interactionMode: 'default', branch: null, worktreePath: null, createdAt });
  const command = { type: 'thread.turn.start', commandId: randomUUID(), threadId, runtimeMode: 'full-access', interactionMode: 'default', createdAt,
    message: { messageId: randomUUID(), role: 'user', text: '你好\u2028world', attachments: [] } };
  await f.dispatch(command);
  await eventually(async () => {
    const snapshot = await f.get('/api/orchestration/threads/' + threadId);
    return snapshot.thread.messages.some(m => m.role === 'assistant' && m.text === 'Reply: 你好\u2028world' && !m.streaming) && snapshot;
  });
  await call(await f.ws(), 'orchestration.dispatchCommand', command); // Cross-transport retry is a native T3 receipt.
  await delay(200);
  const files = await sessionFiles(directory); assert.equal(files.length, 1);
  const records = (await readFile(files[0], 'utf8')).trim().split('\n').map(JSON.parse);
  assert.equal(records.filter(r => r.command === 'prompt').length, 1);
  assert(records.every(r => r.secretInherited === false));
  assert.equal((await readdir(join(directory, 'server-owned'))).includes('native-receipts.json'), false);
  await f.close();
  f = await open(directory);
  const shell = await f.get('/api/orchestration/shell');
  assert.equal(shell.threads[0].id, threadId); assert.equal(shell.projects[0].id, projectId);
  const detail = await f.get('/api/orchestration/threads/' + threadId);
  assert(detail.thread.messages.some(m => m.text === 'Reply: 你好\u2028world'));
  await f.dispatch(command); // Restart does not resend the accepted prompt.
  await delay(200);
  assert.equal((await readFile(files[0], 'utf8')).split('\n').filter(line => line.includes('"command":"prompt"')).length, 1);
  // A new turn after restart resumes the same provider-owned session.
  const resumedCommand = { ...command, commandId: randomUUID(), createdAt: new Date().toISOString(),
    message: { ...command.message, messageId: randomUUID(), text: 'resumed' } };
  await f.dispatch(resumedCommand);
  await eventually(async () => (await f.get('/api/orchestration/threads/' + threadId)).thread.messages.some(m => m.text === 'Reply: resumed' && !m.streaming));
  assert.deepEqual(await sessionFiles(directory), files);
});

test('native T3 command reactor routes model changes and cancellation into the Pi adapter', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-server-cancel-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const projectId = randomUUID(), threadId = randomUUID(), createdAt = new Date().toISOString();
  await f.dispatch({ type: 'project.create', commandId: randomUUID(), projectId, title: 'Cancel test', workspaceRoot: directory, createdAt });
  await f.dispatch({ type: 'thread.create', commandId: randomUUID(), projectId, threadId, title: 'Cancel Thread',
    modelSelection: { instanceId: 'pi', model: 'test/model' }, runtimeMode: 'full-access', interactionMode: 'default', branch: null, worktreePath: null, createdAt });
  await f.dispatch({ type: 'thread.turn.start', commandId: randomUUID(), threadId, createdAt, runtimeMode: 'full-access', interactionMode: 'default',
    modelSelection: { instanceId: 'pi', model: 'test/other', options: [{ id: 'thinkingLevel', value: 'high' }] },
    message: { messageId: randomUUID(), role: 'user', text: 'wait', attachments: [] } });
  await eventually(async () => {
    const files = await sessionFiles(directory);
    return files.length && (await readFile(files[0], 'utf8')).includes('"command":"prompt"');
  });
  const beforeSteer = (await f.get('/api/orchestration/threads/' + threadId)).thread.latestTurn;
  const steering = { type: 'thread.turn.start', commandId: randomUUID(), threadId,
    createdAt: new Date().toISOString(), runtimeMode: 'full-access', interactionMode: 'default',
    message: { messageId: randomUUID(), role: 'user', text: 'change direction', attachments: [] } };
  await f.dispatch(steering);
  await eventually(async () => {
    const files = await sessionFiles(directory);
    return (await readFile(files[0], 'utf8')).includes('"streamingBehavior":"steer"');
  });
  await f.dispatch(steering); // Receipt retry must not enqueue the steer twice.
  const afterSteer = (await f.get('/api/orchestration/threads/' + threadId)).thread.latestTurn;
  assert.equal(afterSteer.turnId, beforeSteer.turnId);
  assert.equal(afterSteer.state, beforeSteer.state);
  await call(await f.ws(), 'orchestration.dispatchCommand', { type: 'thread.turn.interrupt', commandId: randomUUID(), threadId, createdAt: new Date().toISOString() });
  await eventually(async () => {
    const files = await sessionFiles(directory);
    return (await readFile(files[0], 'utf8')).includes('"command":"abort"');
  });
  await eventually(async () => (await f.get('/api/orchestration/threads/' + threadId)).thread.latestTurn?.state === 'interrupted');
  const files = await sessionFiles(directory);
  const records = (await readFile(files[0], 'utf8')).trim().split('\n').map(JSON.parse);
  assert.equal(records.filter(r => r.command === 'prompt').length, 2);
  assert.equal(records.filter(r => r.streamingBehavior === 'steer').length, 1);
  assert.equal(records.filter(r => r.command === 'set_thinking_level').length, 1);
  assert.equal(records.filter(r => r.command === 'abort').length, 1);
  // No retired desktop command IPC was used: all mutations above go through
  // the official orchestration endpoint and the provider-owned fixture log.
  assert.equal(records.some(r => r.command === 'desktop.request'), false);
});
