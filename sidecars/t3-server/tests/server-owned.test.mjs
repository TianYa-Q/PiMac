import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, readFile, writeFile, chmod, rename } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createServerGateway, fixtureEnvironment, nativeDrivers, prepareProtocolServer } from './fixtures/protocol-server.mjs';
import { call, readStream } from '../generated/client.mjs';
const token = 'ab'.repeat(32);
const delay = ms => new Promise(r => setTimeout(r, ms));
async function eventually(fn) {
  for (let n = 0; n < 200; n++) { const value = await fn(); if (value) return value; await delay(50); }
  throw new Error('Timed out waiting for official V2 projection');
}
async function open(directory) {
  const binary = join(directory, 'fixture-pi');
  await writeFile(binary, `#!/bin/sh\nif [ -f '${join(directory, 'fixture-extra-model')}' ]; then export PIMAC_FIXTURE_EXTRA_MODEL=1; fi\nexec '${process.execPath}' '${new URL('./fixtures/pi.mjs', import.meta.url).pathname}' "$@"\n`);
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

test('settled threads can return to active and resume the preserved Pi conversation', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-settlement-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const threadId = await f.create();
  await f.dispatch(f.message(threadId, 'before settlement'));
  await eventually(async () => (await f.snapshot(threadId)).runs.some(r => r.status === 'completed'));
  const projection = await f.snapshot(threadId);
  const lastMessageAt = [
    ...projection.messages.map(message => message.createdAt),
    ...projection.visibleTurnItems.map(row => row.item)
      .filter(item => ['user_message', 'assistant_message', 'reasoning', 'compaction'].includes(item.type))
      .map(item => item.startedAt ?? item.updatedAt),
  ].sort().at(-1);
  assert(projection.visibleTurnItems.some(row => row.item.type === 'assistant_message'));
  const shellRow = async () => (await f.get('/api/orchestration/shell')).threads.find(row => row.id === threadId);
  assert.equal((await shellRow()).latestMessageAt, lastMessageAt);
  await f.dispatch({ type: 'thread.settle', threadId });
  assert.equal((await f.snapshot(threadId)).thread.settledOverride, 'settled');
  const settledRow = await shellRow();
  assert.equal(settledRow.latestMessageAt, lastMessageAt);
  assert.notEqual(settledRow.latestMessageAt, settledRow.settledAt);
  await f.dispatch({ type: 'thread.unsettle', threadId, reason: 'user' });
  const reopened = (await f.snapshot(threadId)).thread;
  assert.equal(reopened.settledOverride, 'active');
  assert.equal(reopened.settledAt, null);
  assert.equal((await shellRow()).latestMessageAt, lastMessageAt);
  await f.dispatch(f.message(threadId, 'after settlement'));
  await eventually(async () => (await f.snapshot(threadId)).runs.filter(r => r.status === 'completed').length === 2);
  const records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert(records.some(r => r.command === 'switch_session'));
});

test('parent settlement covers descendants atomically and leaves unrelated threads active', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-settlement-tree-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const parent = await f.create(), unrelated = await f.create();
  await f.dispatch(f.message(parent, 'fork source'));
  await eventually(async () => (await f.snapshot(parent)).runs.some(r => r.status === 'completed'));
  const fork = async sourceThreadId => {
    const targetThreadId = randomUUID();
    await f.dispatch({ type: 'thread.fork', sourceThreadId, targetThreadId,
      sourcePoint: { type: 'latest_stable' }, createdBy: 'user', creationSource: 'web' });
    return targetThreadId;
  };
  const child = await fork(parent);
  await f.dispatch(f.message(child, 'nested fork source'));
  const childResult = await eventually(async () => {
    const projection = await f.snapshot(child);
    return projection.runs.some(r => ['completed', 'failed'].includes(r.status)) ? projection : null;
  });
  assert(childResult.runs.some(r => r.status === 'completed'), JSON.stringify(childResult.runs));
  const grandchild = await fork(child);
  await f.dispatch(f.message(grandchild, 'active descendant'));
  await assert.rejects(f.dispatch({ type: 'thread.settle', threadId: parent }));
  for (const id of [parent, child, grandchild]) {
    assert.notEqual((await f.snapshot(id)).thread.settledOverride, 'settled');
  }
  await eventually(async () => (await f.snapshot(grandchild)).runs.some(r => r.status === 'completed'));
  const command = { type: 'thread.settle', threadId: parent, commandId: randomUUID() };
  await f.dispatch(command);
  for (const id of [parent, child, grandchild]) {
    assert.equal((await f.snapshot(id)).thread.settledOverride, 'settled');
  }
  assert.notEqual((await f.snapshot(unrelated)).thread.settledOverride, 'settled');
  await f.dispatch(command);
  // 恢复父会话不擅自恢复已完成的子任务。
  await f.dispatch({ type: 'thread.unsettle', threadId: parent, reason: 'user' });
  assert.equal((await f.snapshot(parent)).thread.settledOverride, 'active');
  assert.equal((await f.snapshot(child)).thread.settledOverride, 'settled');
});

test('account rotation status survives native adapter and private gateway without quota queries', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-account-selection-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const first = await f.create(), second = await f.create();
  const selection = async threadID => {
    const response = await fetch(`http://127.0.0.1:${f.gateway.server.address().port}/internal/auth/account-status`, {
      method: 'POST', headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
      body: JSON.stringify({ threadID, provider: 'openai', selectionOnly: true }),
    });
    assert.equal(response.status, 200);
    return JSON.parse((await response.json()).payload);
  };
  assert.equal((await selection(first)).sessionSelection, undefined);
  for (const [threadId, name] of [[first, 'X'], [second, 'X'], [first, 'Y']]) {
    await f.dispatch(f.message(threadId, 'account-selection-' + name));
    await eventually(async () => (await selection(threadId)).sessionSelection?.activeAccount === name);
    await eventually(async () => (await f.snapshot(threadId)).runs.every(run => run.status === 'completed'));
  }
  assert.equal((await selection(first)).sessionSelection.activeAccount, 'Y');
  assert.equal((await selection(second)).sessionSelection.activeAccount, 'X');
  assert.equal((await selection(first)).selectionOnly, true);
  assert.deepEqual((await selection(first)).accounts, []);
});

test('Pi session discovers T3 MCP scheduling tools while invalid credentials remain rejected', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-mcp-scheduling-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  for (const authorization of [undefined, 'Bearer invalid', 'Bearer ' + token]) {
    const response = await fetch(f.gateway.serverURL + '/mcp', { method: 'POST',
      headers: { 'content-type': 'application/json', ...(authorization ? { authorization } : {}) },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} }) });
    assert.equal(response.status, 401);
  }
  const threadId = await f.create();
  await f.dispatch(f.message(threadId, 'mcp-discovery'));
  const projection = await eventually(async () => {
    const projection = await f.snapshot(threadId);
    return projection.runs.some(run => ['completed', 'failed'].includes(run.status)) ? projection : null;
  });
  assert(projection.runs.some(run => run.status === 'completed'), JSON.stringify(projection.runs));
  assert(projection.visibleTurnItems.some(row => row.item.text?.includes('schedule_task')),
    JSON.stringify(projection.visibleTurnItems));
  const { tasks } = await f.rpc('scheduledTasks.list', {});
  const task = tasks.find(task => task.title === 'MCP acceptance timer');
  assert(task, 'schedule_task must persist a real task through the official scheduler');
  assert.equal(task.threadId, threadId);
  assert(task.nextRunAt);
});

test('MCP official catalog includes alternate models and delegation honors explicit targets', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-mcp-targets-'));
  await writeFile(join(directory, 'fixture-extra-model'), 'advertise an alternate model');
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  const threadId = await f.create();
  await f.gateway.official.management.modelCatalog();
  const { providers } = await f.rpc('server.getConfig');
  assert(providers.find(provider => provider.instanceId === 'pi').models.some(model => model.slug === 'test/alternate'));
  await f.dispatch(f.message(threadId, 'mcp-model-targets'));
  const projection = await eventually(async () => {
    const p = await f.snapshot(threadId);
    const items = p.visibleTurnItems.map(row => row.item);
    if (items.some(item => item.text?.includes('"modelTargets":true'))) return p;
    if (p.runs.some(run => ['completed', 'failed'].includes(run.status))) {
      assert.fail(JSON.stringify({ runs: p.runs, items }));
    }
    return null;
  });
  const report = JSON.parse(projection.visibleTurnItems.map(row => row.item)
    .find(item => item.text?.includes('"modelTargets":true')).text);
  const decode = result => JSON.parse(result.content.find(block => block.type === 'text').text);
  assert(!report.capabilities.isError);
  const caps = decode(report.capabilities);
  assert.equal(caps.inheritedModel, 'test/model');
  assert.equal(caps.inheritedProviderInstanceId, 'pi');
  // 状态列表隐藏禁用项，MCP 仍暴露完整官方目录，不添加宿主权限/委派白名单。
  assert.deepEqual(providers.map(provider => provider.driver), ['pi']);
  assert.deepEqual(caps.providers.map(provider => provider.providerInstanceId).sort(),
    [...nativeDrivers, 'pi'].sort());
  const pi = caps.providers.find(provider => provider.providerInstanceId === 'pi');
  assert.deepEqual(pi.models.map(model => model.id).sort(),
    providers.find(provider => provider.instanceId === 'pi').models.map(model => model.slug).sort());
  assert(pi.models.some(model => model.id === 'test/model'));
  assert(pi.models.some(model => model.id === 'test/alternate'));
  assert.equal(pi.canRunChildTask, true);
  assert.equal(pi.canRunCrossProviderChildTask, true);
  const expectedModels = ['test/model', 'test/alternate', 'test/alternate'];
  assert.equal(report.accepted.length, expectedModels.length);
  const tasks = report.accepted.map((result, index) => {
    assert(!result.isError, JSON.stringify(result));
    const task = decode(result);
    assert.equal(task.model, expectedModels[index]);
    assert.equal(task.providerInstanceId, 'pi');
    return task;
  });
  // 不仅检查工具回执，还验证子线程实际使用显式模型并完成执行，避免静默回退到父模型。
  const children = await eventually(async () => {
    const p = await f.snapshot(threadId);
    return p.subagents.length === tasks.length && p.subagents.every(child => child.childThreadId !== null)
      ? p.subagents : null;
  });
  for (const [index, task] of tasks.entries()) {
    const child = children.find(child => child.id === task.taskId);
    assert(child, JSON.stringify({ task, children }));
    const projection = await eventually(async () => {
      const p = await f.snapshot(encodeURIComponent(child.childThreadId));
      return p.runs.some(run => ['completed', 'failed'].includes(run.status)) ? p : null;
    });
    assert.equal(projection.thread.modelSelection.model, expectedModels[index]);
    assert.equal(projection.thread.modelSelection.instanceId, 'pi');
    assert(projection.runs.some(run => run.status === 'completed'), JSON.stringify(projection.runs));
  }
});

test('protocol fixtures ignore developer credentials and never launch native providers for first-message titles', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-provider-isolation-'));
  const previous = { ...process.env };
  let f;
  t.after(async () => {
    try { await f?.close(); } finally {
      for (const key of Object.keys(process.env)) delete process.env[key];
      Object.assign(process.env, previous);
      await rm(directory, { recursive: true, force: true });
    }
  });
  const traps = join(directory, 'native-traps'), marker = join(directory, 'unexpected-provider');
  await mkdir(traps, { mode: 0o700 });
  // 若启动探测、默认模型或后台标题生成误走本机 Provider，留下可断言的证据。
  for (const name of ['codex', 'claude', 'cursor', 'cursor-agent', 'agent', 'grok', 'opencode', 'antigravity', 'muse', 'pi']) {
    const binary = join(traps, name);
    await writeFile(binary, `#!/bin/sh\nprintf '%s\\n' '${name}'\" $*\" >> '${marker}'\nexit 97\n`, { mode: 0o700 });
  }
  process.env.PATH = traps + ':' + previous.PATH;
  for (const key of ['OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR',
    'XDG_DATA_HOME', 'GROK_HOME', 'PI_CODING_AGENT_DIR', 'PI_CODING_AGENT_PACKAGE_DIR', 'NODE_OPTIONS']) {
    process.env[key] = 'developer-environment-must-not-be-used';
  }
  // 模拟旧版只写 Pi 的真实设置：官方缺省槽会隐式启用 Codex/Claude，迁移必须补全关闭项。
  prepareProtocolServer(directory, { binaryPath: join(directory, 'fixture-pi') });
  const settingsFile = join(directory, 'server-owned', 'userdata', 'settings.json');
  const legacySettings = JSON.parse(await readFile(settingsFile, 'utf8'));
  for (const driver of nativeDrivers) delete legacySettings.providerInstances[driver];
  await writeFile(settingsFile, JSON.stringify(legacySettings));
  f = await open(directory);
  assert.equal(process.env.OPENAI_API_KEY, undefined);
  assert.equal(process.env.ANTHROPIC_API_KEY, undefined);
  assert.equal(process.env.NODE_OPTIONS, undefined);
  assert.equal(process.env.HOME, fixtureEnvironment(directory, {}).HOME);
  const { settings, providers } = await f.rpc('server.getConfig');
  assert.equal(settings.textGenerationModelSelection.instanceId, 'pi');
  assert.equal(settings.textGenerationModelSelection.model, 'test/model');
  assert.equal(settings.defaultModelSelection.instanceId, 'pi');
  for (const driver of nativeDrivers) assert.equal(settings.providerInstances[driver]?.enabled ?? false, false, driver);
  assert.deepEqual(providers.map(provider => provider.driver), ['pi']);
  assert(providers[0].models.some(model => model.slug === 'test/model'));
  const refreshed = await f.rpc('server.refreshProviders', {});
  assert.deepEqual(refreshed.providers.map(provider => provider.driver), ['pi']);
  // 保留官方原生浏览器等能力默认值；隔离的只是测试 Provider，非生产能力开关。
  assert.equal(settings.enableAgentBrowserAccess, true);
  const threadId = await f.create('New thread');
  await f.dispatch(f.message(threadId, 'fixture-only title generation'));
  await eventually(async () => (await f.snapshot(threadId)).runs.some(run => run.status === 'completed'));
  await eventually(async () => (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).includes('get_last_assistant_text'));
  await f.close();
  const launches = await readFile(marker, 'utf8').catch(error => { if (error.code === 'ENOENT') return ''; throw error; });
  assert.equal(launches, '', 'nonfixture Provider executable launched');
  const probes = await readFile(join(directory, 'fixture-native-probes.log'), 'utf8')
    .catch(error => { if (error.code === 'ENOENT') return ''; throw error; });
  assert.equal(probes, '', 'disabled providers must not run even installation/version probes');
});

test('official settings can enable native discovery later and restart does not reset that preference', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-provider-opt-in-'));
  let f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  assert.deepEqual((await f.rpc('server.getConfig')).providers.map(p => p.driver), ['pi']);
  await f.rpc('server.updateSettings', { patch: {}, providerInstanceMutation: {
    operation: 'upsert', instanceId: 'codex', instance: { driver: 'codex', enabled: true, config: { setupMode: 'managed' } },
  } });
  await eventually(async () => (await f.rpc('server.getConfig')).providers.some(p => p.instanceId === 'codex' && p.enabled));
  await eventually(async () => (await readFile(join(directory, 'fixture-native-probes.log'), 'utf8').catch(() => '')).includes('codex --version'));
  await f.close();
  f = await open(directory);
  assert.equal((await f.rpc('server.getSettings')).providerInstances.codex.enabled, true);
  await eventually(async () => (await f.rpc('server.getConfig')).providers.some(p => p.driver === 'codex'));
  await f.rpc('server.updateSettings', { patch: {}, providerInstanceMutation: {
    operation: 'upsert', instanceId: 'codex', instance: { driver: 'codex', enabled: false, config: { setupMode: 'managed' } },
  } });
  await eventually(async () => (await f.rpc('server.getConfig')).providers.every(p => p.driver === 'pi'));
});

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

test('legacy visibility migrates once and never overwrites official preferences on restart', async t => {
  const root = new URL('../../../tmp/', import.meta.url).pathname;
  await mkdir(root, { recursive: true });
  const directory = await mkdtemp(join(root, 'legacy-model-visibility-'));
  await mkdir(join(directory, 'server-owned'), { mode: 0o700 });
  await writeFile(join(directory, 'server-owned/model-preferences.json'), JSON.stringify({
    hiddenModels: ['test/legacy'], defaultModel: null,
  }), { mode: 0o600 });
  let f;
  t.after(async () => { await f?.close(); });
  f = await open(directory);
  assert.deepEqual((await f.rpc('server.getSettings')).providerModelPreferences.pi.hiddenModels, ['test/legacy']);
  await f.rpc('server.updateSettings', { patch: {
    setModelsHidden: [{ provider: 'pi', model: 'test/legacy', hidden: false }, { provider: 'pi', model: 'test/model', hidden: true }],
    setProviderModelOrder: { provider: 'pi', modelOrder: ['test/model', 'default'] },
  } });
  await f.close();
  // 迁移后官方设置独立存在；过时旧文件即使损坏，也不再参与运行。
  await writeFile(join(directory, 'server-owned/model-preferences.json'), '{', { mode: 0o600 });
  f = await open(directory);
  assert.deepEqual((await f.rpc('server.getSettings')).providerModelPreferences.pi, {
    hiddenModels: ['test/model'], modelOrder: ['test/model', 'default'],
  });
});

test('official Pi discovery, model preferences, and protocol authorization', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-official-config-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  await f.gateway.official.management.modelCatalog();
  const config = await f.rpc('server.getConfig');
  assert.deepEqual(config.providers.map(provider => provider.driver), ['pi']);
  assert(config.providers.find(provider => provider.instanceId === 'pi').models.some(m => m.slug === 'test/model'));
  assert.equal((await fetch(f.gateway.serverURL + '/api/orchestration/shell', { headers: { 'x-t3-orchestration-protocol': '2' } })).status, 401);
  await assert.rejects(call(await f.ws('1'), 'server.getConfig'));
  await f.rpc('server.updateSettings', { patch: { setModelsHidden: [{ provider: 'pi', model: 'test/model', hidden: true }] } });
  const updated = await f.rpc('server.getConfig');
  assert.deepEqual(updated.settings.defaultModelSelection, config.settings.defaultModelSelection);
  assert.deepEqual((await f.rpc('server.getSettings')).providerModelPreferences.pi.hiddenModels, ['test/model']);
  assert(!updated.providers.find(provider => provider.instanceId === 'pi').models.some(m => m.slug === 'test/model'));
  assert(!(await f.rpc('server.refreshProviders', {})).providers.find(provider => provider.instanceId === 'pi').models.some(m => m.slug === 'test/model'));
  const events = await readStream(await f.ws(), 'subscribeServerConfig', {}, { count: 2,
    filter: event => event.type === 'snapshot' || event.type === 'providerStatuses',
    onItem: async event => {
      if (event.type === 'snapshot') {
        assert(!event.config.providers.find(provider => provider.instanceId === 'pi').models.some(m => m.slug === 'test/model'));
        await f.rpc('server.updateSettings', { patch: { setModelsHidden: [{ provider: 'pi', model: 'test/model', hidden: false }] } });
      }
    } });
  const visible = events.find(event => event.type === 'providerStatuses');
  assert(events.filter(event => event.type === 'snapshot').every(event => event.config.providers.every(p => p.driver === 'pi')));
  assert.deepEqual(visible.payload.providers.map(provider => provider.driver), ['pi']);
  assert(visible.payload.providers.find(provider => provider.instanceId === 'pi').models.some(m => m.slug === 'test/model'));
  const hiddenEvents = await readStream(await f.ws(), 'subscribeServerConfig', {}, { count: 2,
    filter: event => event.type === 'snapshot' || event.type === 'providerStatuses',
    onItem: async event => {
      if (event.type === 'snapshot') {
        assert(event.config.providers.find(provider => provider.instanceId === 'pi').models.some(m => m.slug === 'test/model'));
        await f.rpc('server.updateSettings', { patch: { setModelsHidden: [{ provider: 'pi', model: 'test/model', hidden: true }] } });
      }
    } });
  assert(!hiddenEvents.find(event => event.type === 'providerStatuses').payload.providers.find(provider => provider.instanceId === 'pi').models.some(m => m.slug === 'test/model'));
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

test('Enter during compaction queues once and resumes after compaction', async t => {
  const directory = await mkdtemp(join(process.cwd(), '../../tmp/compaction-enter-'));
  const f = await open(directory);
  t.after(async () => { await f.close(); });
  const threadId = await f.create();
  await f.dispatch(f.message(threadId, 'before compaction'));
  await eventually(async () => (await f.snapshot(threadId)).runs.some(run => run.status === 'completed'));
  const barrier = join(directory, 'fixture-hold-compaction');
  await writeFile(barrier, 'hold');
  await f.dispatch(f.message(threadId, '/compact'));
  await eventually(async () => (await f.snapshot(threadId)).turnItems.some(item =>
    item.type === 'compaction' && item.status === 'running'));
  const active = (await f.snapshot(threadId)).runs.find(run => run.status === 'running');
  assert(active);
  // 仅将 Enter 的软意图降为排队；调用方显式要求 steering 时沿用官方拒绝语义。
  await assert.rejects(f.dispatch(f.message(threadId, 'explicit steer', {
    dispatchMode: { type: 'steer_active', targetRunId: active.id },
  })), error => error.detail?.includes('Wait for context compaction'));
  const message = f.message(threadId, 'continue after compaction', {
    dispatchMode: { type: 'queue_after_active' }, deliveryIntent: 'steer',
  });
  await f.dispatch(message);
  await f.dispatch(message);
  const queued = await f.snapshot(threadId);
  assert.equal(queued.runs.filter(run => run.status === 'queued').length, 1);
  let records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert(!records.some(record => record.message === message.text));
  await rename(barrier, barrier + '-released');
  await eventually(async () => (await f.snapshot(threadId)).runs.filter(run => run.status === 'completed').length === 3);
  const completed = await f.snapshot(threadId);
  assert.equal(completed.messages.filter(row => row.id === message.messageId).length, 1);
  assert(completed.visibleTurnItems.some(row => row.item.text === 'Reply: ' + message.text));
  records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(JSON.parse);
  assert.equal(records.filter(record => record.message === message.text).length, 1);
  // 压缩结束后的同一 Enter 意图仍应正常启动新一轮，不遗留本地等待状态。
  await f.dispatch(f.message(threadId, 'after compaction', {
    dispatchMode: { type: 'queue_after_active' }, deliveryIntent: 'steer',
  }));
  await eventually(async () => (await f.snapshot(threadId)).runs.filter(run => run.status === 'completed').length === 4);
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
