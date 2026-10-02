import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readdir, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { providerFixture } from '../generated/provider-harness.mjs';
import { PiRPC } from '../pi-rpc.mjs';
const config = { binaryPath: process.execPath, binaryArgs: [new URL('./fixtures/pi.mjs', import.meta.url).pathname] };
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-pi-driver-'));
  const f = await providerFixture({ directory, config });
  t.after(async () => { await f.close(); await rm(directory, { force: true, recursive: true }); });
  const start = (threadId = 'thread-a', options = {}) => f.run(f.adapter.startSession({ threadId, cwd: directory,
    runtimeMode: 'full-access', modelSelection: { instanceId: 'pi', model: 'test/model' }, ...options }));
  const send = (input, options = {}) => f.run(f.adapter.sendTurn({ threadId: 'thread-a', input, ...options }));
  const records = async () => {
    const root = join(directory, 'pi-sessions'); const entries = [];
    for (const instance of await readdir(root)) for (const file of await readdir(join(root, instance))) {
      entries.push(...(await readFile(join(root, instance, file), 'utf8')).trim().split('\n').map(JSON.parse));
    }
    return entries;
  };
  return { ...f, directory, start, send, records };
}

test('provider is the single process owner; concurrent starts coalesce, turns cannot race', async t => {
  const f = await fixture(t);
  const [a, b] = await Promise.all([f.start(), f.start()]);
  assert.deepEqual(a, b); assert.equal((await f.run(f.adapter.listSessions())).length, 1);
  const result = await f.send('wait');
  await assert.rejects(f.send('duplicate'));
  await assert.rejects(f.run(f.adapter.interruptTurn('thread-a', 'stale-turn')));
  await f.run(f.adapter.interruptTurn('thread-a', result.turnId));
  assert.equal((await f.run(f.adapter.listSessions()))[0].status, 'ready');
  await delay(10);
  assert.equal(f.events.filter(e => e.type === 'turn.aborted').length, 1);
  assert.equal(f.events.find(e => e.type === 'turn.aborted').payload.reason, 'interrupted');
  assert.equal((await f.records()).filter(r => r.command === 'prompt').length, 1);
  await f.run(f.adapter.stopSession('thread-a'));
  assert.equal(await f.run(f.adapter.hasSession('thread-a')), false);
});

test('agent_end is not settlement; Unicode text and final turn states use T3 events', async t => {
  const f = await fixture(t); await f.start(); await f.send('你好\u2028world');
  await delay(15);
  assert.equal(f.events.filter(e => e.type === 'turn.completed').length, 0);
  assert.equal((await f.run(f.adapter.listSessions()))[0].status, 'running');
  await delay(110);
  assert.equal(f.events.find(e => e.type === 'content.delta').payload.delta, 'Reply: 你好\u2028world');
  assert.equal(f.events.filter(e => e.type === 'turn.completed').length, 1);
  assert.equal(f.events.find(e => e.type === 'turn.completed').payload.state, 'completed');
  assert(f.events.every(e => e.providerInstanceId === 'pi'));
  assert.equal((await f.run(f.adapter.listSessions()))[0].status, 'ready');
  await f.send('/handled'); await delay(10);
  assert.equal(f.events.filter(e => e.type === 'turn.completed').length, 2);
  await f.send('tools'); await delay(110);
  const tools = f.events.filter(e => e.itemId === 'tool-1');
  assert.deepEqual(tools.map(e => e.type), ['item.started', 'item.updated', 'item.completed']);
  assert.equal(tools[2].payload.status, 'completed');
});




test('Pi RPC has bounded unknown-outcome deadlines, drains replies and shuts down on EOF', async () => {
  const rpc = new PiRPC({ ...config, args: ['--no-session'], timeoutMs: 100 });
  try {
    const state = await rpc.request({ type: 'get_state' }); assert.equal(state.isStreaming, false);
    await assert.rejects(rpc.request({ type: 'unknown-command' }), /Pi rejected/);
    await assert.rejects(rpc.request({ type: 'prompt', message: 'no-response' }), /outcome unknown/);
    assert.equal(rpc.pending.size, 0);
  } finally { await rpc.stop(); }
  assert.equal(rpc.closed, true);
  await assert.rejects(rpc.request({ type: 'get_state' }), /closed/);
});

test('provider instances isolate the same thread ID and scope disposal stops every runtime', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-pi-instances-'));
  const a = await providerFixture({ directory, config, instanceId: 'a' });
  const b = await providerFixture({ directory, config, instanceId: 'b' });
  t.after(async () => { await a.close(); await b.close(); await rm(directory, { recursive: true, force: true }); });
  for (const f of [a, b]) await f.run(f.adapter.startSession({ threadId: 'shared-thread', cwd: directory, runtimeMode: 'full-access' }));
  await a.run(a.adapter.sendTurn({ threadId: 'shared-thread', input: 'wait' }));
  await a.close();
  assert.equal(await a.run(a.adapter.hasSession('shared-thread')), false);
  assert.equal(await b.run(b.adapter.hasSession('shared-thread')), true);
  assert.equal((await readdir(join(directory, 'pi-sessions'))).length, 2);
});

test('disabled provider does not spawn Pi for discovery or start a session', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-pi-disabled-'));
  const f = await providerFixture({ directory, enabled: false, config: { binaryPath: '/must-not-run' } });
  t.after(async () => { await f.close(); await rm(directory, { recursive: true, force: true }); });
  assert.equal((await f.run(f.instance.snapshot.getSnapshot)).status, 'disabled');
  await assert.rejects(f.run(f.adapter.startSession({ threadId: 'a', cwd: directory, runtimeMode: 'full-access' })));
  assert.deepEqual(await readdir(directory), []);
});

