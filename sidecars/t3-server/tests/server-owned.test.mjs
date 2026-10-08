import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, writeFile, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';
import { call, readStream } from '../generated/client.mjs';
const token = 'ab'.repeat(32);
const delay = ms => new Promise(r => setTimeout(r, ms));
async function eventually(fn) {
  for (let n = 0; n < 200; n++) { const value = await fn(); if (value) return value; await delay(50); }
  throw new Error('Timed out waiting for official V2 projection');
}
async function open(directory) {
  const binary = join(directory, 'fixture-pi');
  await writeFile(binary, `#!/bin/sh\nexec '${process.execPath}' '${new URL('./fixtures/pi.mjs', import.meta.url).pathname}' "$@"\n`);
  await chmod(binary, 0o700);
  const gateway = await createServerGateway({ token, directory, piConfig: { binaryPath: binary } });
  await new Promise(r => gateway.server.listen(0, '127.0.0.1', r));
  const base = gateway.serverURL;
  const { token: credential } = await gateway.official.management.desktopSession();
  const headers = { authorization: 'Bearer ' + credential, 'content-type': 'application/json', 'x-t3-orchestration-protocol': '2' };
  const get = async pathname => {
    const response = await fetch(base + pathname, { headers });
    assert.equal(response.status, 200, await response.clone().text()); return response.json();
  };
  const ws = async (protocol = '2') => {
    const response = await fetch(base + '/api/auth/websocket-ticket', { method: 'POST', headers, body: '{}' });
    const ticket = await response.json(); assert.equal(response.status, 200);
    return base.replace('http:', 'ws:') + '/ws?orchestrationProtocol=' + protocol + '&wsTicket=' + ticket.ticket;
  };
  const rpc = async (method, input) => call(await ws(), method, input);
  const dispatch = fields => rpc('orchestration.dispatchCommand', { commandId: randomUUID(), ...fields });
  let projectId;
  const create = async (title = 'Official thread') => {
    const threadId = randomUUID();
    if (!projectId) {
      projectId = randomUUID();
      await rpc('projects.mutate', { type: 'project.create', commandId: randomUUID(), projectId, title: 'Official Pi', workspaceRoot: directory });
    }
    await dispatch({ type: 'thread.create', projectId, threadId, title, createdBy: 'user', creationSource: 'web',
      modelSelection: { instanceId: 'pi', model: 'test/model' }, runtimeMode: 'full-access', interactionMode: 'default', branch: null, worktreePath: null });
    return threadId;
  };
  const message = (threadId, text, extra = {}) => ({ type: 'message.dispatch', commandId: randomUUID(), threadId,
    messageId: randomUUID(), text, attachments: [], createdBy: 'user', creationSource: 'web', dispatchMode: { type: 'start_immediately' }, ...extra });
  const snapshot = async threadId => (await get('/api/orchestration/threads/' + threadId)).projection;
  return { gateway, get, ws, rpc, dispatch, create, message, snapshot, close: () => gateway.close() };
}

test('server names a desktop draft on its first mobile message without overwriting custom titles', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-mobile-title-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  for (const title of ['新任务', 'New thread', 'My custom title']) {
    const threadId = await f.create(title);
    // Mobile dispatch has no titleSeed and performs no follow-up metadata update.
    await f.dispatch(f.message(threadId, '  手机继续\n  修复问题  '));
    let projection = await f.snapshot(threadId);
    assert.equal(projection.thread.title, title === 'My custom title' ? title : '手机继续 修复问题');
    await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.status === 'completed'));
    await f.dispatch(f.message(threadId, 'second message must not rename'));
    projection = await f.snapshot(threadId);
    assert.notEqual(projection.thread.title, 'second message must not rename');
    if (title === 'My custom title') assert.equal(projection.thread.title, title);
    await eventually(async () => (await f.snapshot(threadId)).runs.filter(r => r.status === 'completed').length === 2);
  }
});

test('official Pi discovery, model preferences, and protocol authorization', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-official-config-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  await f.gateway.official.management.modelCatalog();
  const config = await f.rpc('server.getConfig');
  assert.equal(config.providers[0].driver, 'pi');
  assert(config.providers[0].models.some(m => m.slug === 'test/model'));
  assert.equal((await fetch(f.gateway.serverURL + '/api/orchestration/shell', { headers: { 'x-t3-orchestration-protocol': '2' } })).status, 401);
  await assert.rejects(call(await f.ws('1'), 'server.getConfig'));
  await f.gateway.official.management.modelPreferences({ hiddenModels: ['test/model'], defaultModel: 'test/model' });
  const updated = await f.rpc('server.getConfig');
  assert.equal(updated.settings.defaultModelSelection, null);
  assert(!updated.providers[0].models.some(m => m.slug === 'test/model'));
  assert(!(await f.rpc('server.refreshProviders', {})).providers[0].models.some(m => m.slug === 'test/model'));
  const events = await readStream(await f.ws(), 'subscribeServerConfig', {}, { count: 2,
    filter: event => event.type === 'snapshot' || event.type === 'providerStatuses',
    onItem: async event => {
      if (event.type === 'snapshot') {
        assert(!event.config.providers[0].models.some(m => m.slug === 'test/model'));
        await f.gateway.official.management.modelPreferences({ hiddenModels: [], defaultModel: null });
      }
    } });
  const visible = events.find(event => event.type === 'providerStatuses');
  assert(visible.payload.providers[0].models.some(m => m.slug === 'test/model'));
  const hiddenEvents = await readStream(await f.ws(), 'subscribeServerConfig', {}, { count: 2,
    filter: event => event.type === 'snapshot' || event.type === 'providerStatuses',
    onItem: async event => {
      if (event.type === 'snapshot') {
        assert(event.config.providers[0].models.some(m => m.slug === 'test/model'));
        await f.gateway.official.management.modelPreferences({ hiddenModels: ['test/model'], defaultModel: null });
      }
    } });
  assert(!hiddenEvents.find(event => event.type === 'providerStatuses').payload.providers[0].models.some(m => m.slug === 'test/model'));
  // Hiding is presentation only: a thread can still run the hidden model.
  const threadId = await f.create();
  await f.dispatch(f.message(threadId, 'hidden model'));
  await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.status === 'completed'));
  assert.equal((await f.snapshot(threadId)).thread.modelSelection.model, 'test/model');
  const supervisor = `http://127.0.0.1:${f.gateway.server.address().port}/internal/auth/account-status`;
  const body = JSON.stringify({ provider: 'unsupported' });
  assert.equal((await fetch(supervisor, { method: 'POST', headers: { 'content-type': 'application/json' }, body })).status, 401);
  assert.equal((await fetch(supervisor, { method: 'POST', headers: { authorization: 'Bearer ' + token, origin: 'https://example.com', 'content-type': 'application/json' }, body })).status, 401);
  assert.equal((await fetch(supervisor, { method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' }, body })).status, 400);
  assert.equal((await fetch(f.gateway.serverURL + '/internal/auth/account-status', { method: 'POST', headers: { 'content-type': 'application/json' }, body })).status, 404);
  assert(JSON.parse((await f.gateway.official.management.modelCatalog()).catalogs).pi.some(m => m.slug === 'test/model'));
});

test('official V2 owns receipts, settlement, transcript, restart and native Pi resume', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-official-turn-'));
  let f;
  t.after(async () => { await f?.close(); await rm(directory, { recursive: true, force: true }); });
  f = await open(directory);
  const threadId = await f.create();
  const command = f.message(threadId, '你好\u2028world');
  await f.dispatch(command);
  await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.status === 'completed'));
  let projection = await f.snapshot(threadId);
  assert(projection.visibleTurnItems.some(row => row.item.text === 'Reply: 你好\u2028world'));
  assert(projection.providerThreads[0].nativeThreadRef.nativeId.endsWith('.jsonl'));
  const usage = projection.providerTurns.at(-1);
  assert.equal(usage.turnTokenUsage.outputTokens, 20);
  assert.equal(usage.turnTokenUsage.inputTokens, 190);
  assert.equal(usage.turnTokenUsage.cacheCreationTokens, 10);
  assert.equal(usage.piMetrics.totalCostUsd, 0.012);
  assert(usage.piMetrics.outputDurationMs >= 0);
  await f.dispatch(command);
  let records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert.equal(records.filter(r => r.command === 'prompt').length, 1);
  assert(records.every(r => !r.secretInherited));
  await f.close();
  f = await open(directory);
  assert((await f.get('/api/orchestration/shell')).threads.some(thread => thread.id === threadId));
  await f.dispatch(command);
  await f.dispatch(f.message(threadId, 'resumed'));
  await eventually(async () => (await f.snapshot(threadId)).runs.filter(r => r.status === 'completed').length === 2);
  records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert.equal(records.filter(r => r.command === 'prompt').length, 2);
  assert(records.some(r => r.command === 'switch_session'));
});

test('model response metrics arrive before task settlement and survive completion', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-response-usage-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const threadId = await f.create();
  // Fixture finishes its model response immediately, then settles 1.5s later.
  await f.dispatch(f.message(threadId, 'slow'));
  const live = await eventually(async () => {
    const projection = await f.snapshot(threadId);
    return projection.providerTurns.at(-1)?.piMetrics ? projection : null;
  });
  const turn = live.providerTurns.at(-1);
  assert.equal(turn.status, 'running');
  assert.equal(turn.completedAt, null);
  assert(!live.runs.some(run => run.status === 'completed'));
  assert.equal(turn.turnTokenUsage.outputTokens, 20);
  assert.equal(turn.piMetrics.totalCostUsd, 0.012);
  await eventually(async () => (await f.snapshot(threadId)).runs.some(run => run.status === 'completed'));
  const settled = (await f.snapshot(threadId)).providerTurns.at(-1);
  assert.deepEqual(settled.piMetrics, turn.piMetrics);
  assert.deepEqual(settled.turnTokenUsage, turn.turnTokenUsage);
});

test('T3 Pi Codex-shaped stream preserves AA speed fields on the official wire', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-aa-codex-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const threadId = await f.create();
  await f.dispatch(f.message(threadId, 'aa-codex'));
  const turn = await eventually(async () => {
    const projection = await f.snapshot(threadId);
    const turn = projection.providerTurns.at(-1);
    return turn?.piMetrics?.speedTokens ? turn : null;
  });
  assert.equal(turn.status, 'running');
  assert.equal(turn.piMetrics.speedMethod, 'aa-approx-v1');
  assert.equal(turn.piMetrics.speedTokens, 80);
  assert(turn.piMetrics.speedDurationMs >= 500);
  assert.equal(turn.turnTokenUsage.outputTokens, 600);
  await eventually(async () => (await f.snapshot(threadId)).runs.some(run => run.status === 'completed'));
  assert.deepEqual((await f.snapshot(threadId)).providerTurns.at(-1).piMetrics, turn.piMetrics);
});

test('official scheduler dispatches into Pi and persists across server restart', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-official-schedule-'));
  let f;
  t.after(async () => { await f?.close(); await rm(directory, { recursive: true, force: true }); });
  f = await open(directory);
  const threadId = await f.create();
  const projectId = (await f.get('/api/orchestration/shell')).threads.find(row => row.id === threadId).projectId;
  const { task } = await f.rpc('scheduledTasks.upsert', {
    title: 'Scheduled Pi', prompt: 'scheduled fixture', enabled: false,
    schedule: { type: 'interval', everyMs: 3600000 }, projectId, threadId,
    workspaceStrategy: { type: 'root' }, modelSelection: { instanceId: 'pi', model: 'test/model' },
    runtimeMode: 'full-access', interactionMode: 'default',
  });
  const run = await f.rpc('scheduledTasks.runNow', { id: task.id });
  assert.equal(run.task.lastRunStatus, 'succeeded', run.task.lastRunError);
  assert.equal(run.task.runCount, 1);
  assert.equal(run.task.nextRunAt, null);
  await eventually(async () => (await f.snapshot(threadId)).runs.some(row => row.status === 'completed'));
  assert((await f.snapshot(threadId)).visibleTurnItems.some(row => row.item.text === 'Reply: scheduled fixture'));
  await f.close();
  f = await open(directory);
  const saved = (await f.rpc('scheduledTasks.list', {})).tasks.find(row => row.id === task.id);
  assert.equal(saved.threadId, threadId);
  assert.equal(saved.runCount, 1);
  assert.equal(saved.enabled, false);
  await f.rpc('scheduledTasks.delete', { id: task.id });
  await assert.rejects(f.rpc('scheduledTasks.runNow', { id: task.id }), error => error._tag === 'ScheduledTaskError');
});

test('official Pi tools, model selection, steering and cancellation', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-official-tools-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const threadId = await f.create();
  await f.dispatch(f.message(threadId, 'tools'));
  await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.status === 'completed'));
  const tools = (await f.snapshot(threadId)).turnItems;
  assert(tools.some(item => item.type === 'dynamic_tool' && item.toolName === 'read'));
  const code = tools.find(item => item.toolName === 'codemode');
  const nested = tools.find(item => item.input?.path === 'nested.txt');
  assert(code);
  assert(nested);
  // Build 109-era clients fetch full tool details through the official lazy RPC.
  const detail = await f.rpc('orchestration.getTurnItem', { threadId, itemId: code.id, revision: code.updatedAt });
  assert.equal(detail.item.id, code.id);
  assert.equal(detail.item.toolName, 'codemode');
  assert.equal((await f.rpc('orchestration.getTurnItem', { threadId, itemId: randomUUID() })).item, null);
  const otherThreadId = await f.create();
  assert.equal((await f.rpc('orchestration.getTurnItem', { threadId: otherThreadId, itemId: code.id })).item, null);
  // Upstream Pi currently emits flat tool items; do not add host-owned nesting.
  assert.equal(nested.parentItemId, null);
  assert.equal(tools.find(item => item.input?.path === 'fixture.txt').parentItemId, null);
  await f.dispatch({ type: 'thread.model-selection.set', threadId, modelSelection: { instanceId: 'pi', model: 'test/model', options: [{ id: 'thinking', value: 'high' }] } });
  await f.dispatch(f.message(threadId, 'wait'));
  const active = await eventually(async () => (await f.snapshot(threadId)).runs.find(r => r.status === 'running'));
  await eventually(async () => (await f.snapshot(threadId)).providerTurns.some(turn => turn.status === 'running'));
  const steer = f.message(threadId, 'steer', { dispatchMode: { type: 'steer_active', targetRunId: active.id } });
  await f.dispatch(steer);
  await f.dispatch(steer);
  await f.dispatch({ type: 'run.interrupt', threadId, runId: active.id });
  await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.id === active.id && ['interrupted', 'cancelled'].includes(r.status)));
  const records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert.equal(records.filter(r => r.message === 'steer').length, 1);
  assert(records.some(r => r.streamingBehavior === 'steer'));
  assert(records.some(r => r.command === 'abort'));
});

test('official extension dialogs respond through runtime requests and /compact uses native Pi', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-official-dialog-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const threadId = await f.create();
  await f.dispatch(f.message(threadId, 'dialog'));
  const request = await eventually(async () => (await f.snapshot(threadId)).runtimeRequests.find(r => r.status === 'pending'));
  const item = (await f.snapshot(threadId)).turnItems.find(item => item.requestId === request.id);
  assert.equal(item.type, 'user_input_request');
  await f.dispatch({ type: 'runtime-request.respond', threadId, requestId: request.id, answers: { [item.questions[0].id]: 'official answer' } });
  await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.status === 'completed'));
  assert((await f.snapshot(threadId)).visibleTurnItems.some(row => row.item.text === 'Dialog: official answer'));
  await f.dispatch(f.message(threadId, '/compact'));
  await eventually(async () => (await f.snapshot(threadId)).runs.filter(r => r.status === 'completed').length === 2);
  assert((await f.snapshot(threadId)).turnItems.some(item => item.type === 'compaction'));
  const records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert(records.some(r => r.command === 'compact'));
  assert(!records.some(r => r.command === 'prompt' && r.message === '/compact'));
});

test('Pi tool images survive lazy reads, signed downloads and server restart', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-tool-images-'));
  let f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const threadId = await f.create();
  await f.dispatch(f.message(threadId, 'tool-image'));
  await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.status === 'completed'));
  const item = (await f.snapshot(threadId)).turnItems.find(item => item.toolName === 'generate_image');
  assert(item);
  const otherThreadId = await f.create();
  const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1cAAAAASUVORK5CYII=', 'base64');
  for (const restart of [false, true]) {
    if (restart) { await f.close(); f = await open(directory); }
    const detail = await f.rpc('orchestration.getTurnItem', { threadId, itemId: item.id, revision: item.updatedAt });
    const blocks = Array.isArray(detail.item.output) ? detail.item.output : detail.item.output.content;
    const image = blocks.find(block => block.type === 'image');
    assert.equal(image.mimeType, 'image/png');
    assert.equal(image.data, undefined);
    const resource = { _tag: 'tool-output-image', threadId, itemId: item.id, index: 0 };
    const signed = await f.rpc('assets.createUrl', { resource });
    const asset = await fetch(f.gateway.serverURL + signed.relativeUrl);
    assert.equal(asset.status, 200);
    assert.equal(asset.headers.get('content-type'), 'image/png');
    assert.deepEqual(Buffer.from(await asset.arrayBuffer()), bytes);
    await assert.rejects(f.rpc('assets.createUrl', { resource: { ...resource, threadId: otherThreadId } }));
    await assert.rejects(f.rpc('assets.createUrl', { resource: { ...resource, index: 8 } }));
  }
});

test('official attachment persistence, signed asset access and Pi image delivery', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-official-images-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const threadId = await f.create(), messageId = randomUUID();
  const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1cAAAAASUVORK5CYII=', 'base64');
  const persisted = await f.rpc('assets.persistChatAttachments', { threadId, messageId, attachments: [{
    type: 'image', name: 'fixture.png', mimeType: 'image/png', sizeBytes: bytes.length, dataUrl: 'data:image/png;base64,' + bytes.toString('base64'),
  }] });
  const signed = await f.rpc('assets.createUrl', { resource: { _tag: 'attachment', attachmentId: persisted.attachments[0].id } });
  const asset = await fetch(f.gateway.serverURL + signed.relativeUrl);
  assert.equal(asset.status, 200);
  assert.deepEqual(Buffer.from(await asset.arrayBuffer()), bytes);
  await f.dispatch(f.message(threadId, 'image', { messageId, attachments: persisted.attachments }));
  await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.status === 'completed'));
  const records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert(records.some(r => r.command === 'prompt' && r.imageCount === 1));
});

test('mobile signed HTTP uploads reach Pi and pending attachments can be deleted', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-mobile-images-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const threadId = await f.create();
  const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1cAAAAASUVORK5CYII=', 'base64');
  const metadata = { type: 'image', name: 'phone.png', mimeType: 'image/png', sizeBytes: bytes.length };
  const upload = async signed => fetch(f.gateway.serverURL + signed.relativeUrl, {
    method: 'POST', headers: { 'content-type': metadata.mimeType }, body: bytes,
  });
  const signed = await f.rpc('attachments.createUploadUrl', metadata);
  const response = await upload(signed);
  assert.equal(response.status, 204, await response.text());
  const attachment = { ...metadata, id: signed.attachmentId };
  await f.dispatch(f.message(threadId, 'phone image', { attachments: [attachment] }));
  await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.status === 'completed'));
  const records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert(records.some(r => r.command === 'prompt' && r.imageCount === 1));

  const pending = await f.rpc('attachments.createUploadUrl', metadata);
  assert.equal((await upload(pending)).status, 204);
  await f.rpc('attachments.delete', { attachmentId: pending.attachmentId });
  // Deletion is idempotent for a removed draft attachment.
  await f.rpc('attachments.delete', { attachmentId: pending.attachmentId });
  await assert.rejects(f.rpc('assets.createUrl', { resource: { _tag: 'attachment', attachmentId: pending.attachmentId } }),
    error => error._tag === 'AssetAttachmentNotFoundError');

  assert.equal((await upload({ relativeUrl: '/api/attachments/upload/invalid-token' })).status, 404);
  const wrongSize = await f.rpc('attachments.createUploadUrl', metadata);
  assert.equal((await fetch(f.gateway.serverURL + wrongSize.relativeUrl, { method: 'POST', body: bytes.subarray(1) })).status, 400);
  assert.equal((await fetch(f.gateway.serverURL + signed.relativeUrl, {
    method: 'POST', headers: { origin: 'https://attacker.invalid' }, body: bytes,
  })).status, 403);
});
