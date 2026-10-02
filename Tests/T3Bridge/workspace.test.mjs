import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, rm, writeFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createGateway } from '../../Sources/PiMacApp/Resources/t3-bridge/gateway.mjs';
import { AuthStore } from '../../Sources/PiMacApp/Resources/t3-bridge/auth-store.mjs';
import { WorkspaceProjection } from '../../Sources/PiMacApp/Resources/t3-bridge/vendor/rpc-runtime.mjs';
import { createWorkspaceIPC } from '../../Sources/PiMacApp/Resources/t3-bridge/workspace-ipc.mjs';
import { TOKEN_EXCHANGE_GRANT, BOOTSTRAP_TOKEN_TYPE, ACCESS_TOKEN_TYPE } from '../../Sources/PiMacApp/Resources/t3-bridge/protocol.mjs';
import { readStream, call } from '../../sidecars/t3-rpc/test-client.mjs';
import { validateShell, validateThread, validateShellInput, validateShellItem } from '../../sidecars/t3-rpc/generated/upstream-validation.mjs';

const date = '2026-10-02T10:00:00.000Z';
function source() {
  return { catalog: { projects: [{ path: '/project', title: 'Project', sessions: [{ path: '/saved/a.jsonl', title: 'Existing session', updatedAt: date }] }],
    runtimes: [{ target: 'runtime-a', projectPath: '/project', path: '/saved/a.jsonl', model: 'openai/model', busy: true, connected: true }] },
    detail: { entries: [
      { id: 'ephemeral-user', kind: 'user', text: 'hello', createdAt: date, running: false },
      { id: 'ephemeral-reasoning', kind: 'reasoning', text: 'thinking', createdAt: date, running: false },
      { id: 'ephemeral-assistant', kind: 'assistant', text: 'partial', createdAt: date, running: true },
      { id: 'tool-1', kind: 'tool', text: 'file read', input: 'README.md', title: 'read', createdAt: date, running: false },
    ] } };
}
async function fixture(t, scopes) {
  const data = source(), requests = [];
  const store = new AuthStore();
  const grant = store.createPairing(scopes ? { scopes } : {});
  const auth = store.exchange({ grant_type: TOKEN_EXCHANGE_GRANT, subject_token: grant.credential,
    subject_token_type: BOOTSTRAP_TOKEN_TYPE, requested_token_type: ACCESS_TOKEN_TYPE });
  const session = store.authenticate(`Bearer ${auth.access_token}`);
  let gateway;
  gateway = createGateway({ token: 'ab'.repeat(32), authStore: store, send: message => {
    requests.push(message);
    if (data.block) return;
    if (message.method === 'session.send') {
      if (data.rejectSend) { queueMicrotask(() => gateway.receive({ id: message.id, error: { code: 'session_not_ready' } })); return; }
      data.detail.entries.push({ id: message.messageId, kind: 'user', text: message.text.trim() || '请查看附件。',
        createdAt: '2026-10-02T13:00:00.000Z', running: false });
      data.catalog.projects[0].sessions[0].updatedAt = '2026-10-02T13:00:00.000Z';
      queueMicrotask(() => gateway.receive({ id: message.id, result: { accepted: true } }));
      return;
    }
    queueMicrotask(() => gateway.receive({ id: message.id, result: structuredClone(message.method === 'workspace.catalog'
      ? data.catalog : !message.target && data.savedDetail ? data.savedDetail : data.detail) }));
  } });
  gateway.server.listen(0, '127.0.0.1'); await once(gateway.server, 'listening');
  t.after(() => gateway.close());
  const base = `http://127.0.0.1:${gateway.server.address().port}`;
  const get = path => fetch(base + path, { headers: { authorization: `Bearer ${auth.access_token}` } });
  const ws = () => `${base.replace('http:', 'ws:')}/ws?orchestrationProtocol=1&wsTicket=${store.createTicket(session).ticket}`;
  return { data, requests, gateway, store, session, get, ws };
}

test('HTTP shell and detail project existing sessions, not diagnostic paths or runtime IDs', async t => {
  const f = await fixture(t);
  const shell = await (await f.get('/api/orchestration/shell')).json();
  validateShell(shell);
  const thread = shell.threads[0];
  assert.match(thread.id, /^pimac-thread-[0-9a-f]{64}$/);
  assert.match(thread.projectId, /^pimac-project-[0-9a-f]{64}$/);
  assert.equal(thread.session.status, 'running');
  assert(!JSON.stringify(shell).includes('/saved/a.jsonl'));
  assert(!JSON.stringify(shell).includes('runtime-a'));
  const detail = await (await f.get(`/api/orchestration/threads/${thread.id}`)).json();
  validateThread(detail);
  assert.equal(detail.thread.messages[1].role, 'system');
  assert.equal(detail.thread.activities[0].tone, 'tool');
  assert.equal(detail.thread.messages[2].streaming, true);
  const optedIn = await (await f.get(`/api/orchestration/threads/${thread.id}?reasoningMessages=true`)).json();
  assert.equal(optedIn.thread.messages[1].role, 'reasoning');
  assert.equal(optedIn.thread.messages[1].id, detail.thread.messages[1].id);
  assert.deepEqual(f.requests.at(-1), { ...f.requests.at(-1), method: 'session.read', target: 'runtime-a', sessionPath: '/saved/a.jsonl', projectPath: '/project' });
});

test('real Effect thread subscription streams replacements with stable message IDs', async t => {
  const f = await fixture(t);
  const shell = await (await f.get('/api/orchestration/shell')).json();
  let step = 0;
  const values = await readStream(f.ws(), 'orchestration.subscribeThread', { threadId: shell.threads[0].id, reasoningMessages: true }, {
    count: 3, onItem: item => {
      assert.equal(item.kind, 'snapshot');
      validateThread(item.snapshot);
      if (step++ === 0) f.data.detail.entries[2].text += ' more';
      else { f.data.detail.entries[2].running = false; f.data.detail.entries[2].id = 'history-regenerated-id'; }
    },
  });
  assert.equal(values[0].snapshot.thread.messages[2].id, values[2].snapshot.thread.messages[2].id);
  assert.equal(values[2].snapshot.thread.messages[2].text, 'partial more');
  assert.equal(values[2].snapshot.thread.messages[2].streaming, false);
  assert(values[2].snapshot.snapshotSequence > values[0].snapshot.snapshotSequence);
  assert(f.requests.every(r => ['workspace.catalog', 'session.read'].includes(r.method)));
});

test('shell orders sessions by last user timestamp across projects, with stable ties', async t => {
  const f = await fixture(t);
  f.data.catalog.projects[0].sessions.push(
    { path: '/saved/old.jsonl', title: 'Old', updatedAt: '2026-09-01T10:00:00.000Z' },
    { path: '/saved/recent.jsonl', title: 'Recent', updatedAt: '2026-10-02T11:00:00.000Z' });
  f.data.catalog.projects.push({ path: '/other', title: 'Other', sessions: [
    { path: '/saved/newest.jsonl', title: 'Newest', updatedAt: '2026-10-02T12:00:00.000Z' },
  ] });
  const shell = validateShell(await (await f.get('/api/orchestration/shell')).json());
  assert.deepEqual(shell.threads.map(t => t.title), ['Newest', 'Recent', 'Existing session', 'Old']);
  assert(shell.threads.every(t => t.latestUserMessageAt === t.updatedAt));
  // Exact mobile V2 rule: keyed rows sort lexically, keyless rows by createdAt.
  const mobileSorted = [...shell.threads].reverse().sort((a, b) =>
    a.activeOrderKey.localeCompare(b.activeOrderKey) || a.id.localeCompare(b.id));
  assert.deepEqual(mobileSorted.map(t => t.title), ['Newest', 'Recent', 'Existing session', 'Old']);
  assert.deepEqual(validateShell(await (await f.get('/api/orchestration/shell')).json()).threads, shell.threads);
});

test('catalog-only and not-yet-loaded sessions return real messages with completion markers', async t => {
  const f = await fixture(t);
  f.data.catalog.runtimes = [];
  const shell = await (await f.get('/api/orchestration/shell')).json();
  const id = shell.threads[0].id;
  const response = await f.get(`/api/orchestration/threads/${id}`);
  assert.equal(response.status, 200);
  assert.equal(validateThread(await response.json()).thread.messages[0].text, 'hello');
  assert.equal(f.requests.at(-1).target, undefined);
  const items = await readStream(f.ws(), 'orchestration.subscribeThread', {
    threadId: id, requestCompletionMarker: true,
  }, { count: 2 });
  assert.deepEqual(items.map(i => i.kind), ['snapshot', 'synchronized']);
  assert.equal(items[0].snapshot.thread.messages[0].text, 'hello');
  f.data.catalog.runtimes = source().catalog.runtimes;
  f.data.catalog.runtimes[0].loaded = false;
  assert.equal((await f.get(`/api/orchestration/threads/${id}`)).status, 200);
  assert.equal(f.requests.at(-1).target, 'runtime-a');
});

test('ambiguous runtime ownership cannot fall back to a saved file', async t => {
  const f = await fixture(t);
  f.data.catalog.runtimes.push({ ...f.data.catalog.runtimes[0], target: 'second-runtime' });
  const shell = await (await f.get('/api/orchestration/shell')).json();
  f.requests.length = 0;
  assert.equal((await f.get(`/api/orchestration/threads/${shell.threads[0].id}`)).status, 503);
  assert(f.requests.every(r => r.method === 'workspace.catalog'));
});

test('unchanged history does not keep emitting snapshots while a subscription is idle', async () => {
  const data = source();
  data.catalog.runtimes = [];
  const workspace = new WorkspaceProjection({ environmentId: 'stable-history', intervalMs: 10,
    request: async method => structuredClone(method === 'workspace.catalog' ? data.catalog : data.detail) });
  const shell = await workspace.shellSnapshot();
  const batches = [];
  const stop = workspace.watch('thread', { threadId: shell.threads[0].id, requestCompletionMarker: true },
    batch => batches.push(batch), assert.fail);
  try {
    await new Promise(resolve => setTimeout(resolve, 80));
    assert.equal(batches.length, 1);
    assert.deepEqual(batches[0].map(i => i.kind), ['snapshot', 'synchronized']);
    data.detail.entries[2].text += ' updated';
    await new Promise(resolve => setTimeout(resolve, 50));
    assert.equal(batches.length, 2);
  } finally { stop(); workspace.close(); }
});

test('ordinary histories above the old 256 KiB limit remain readable', async t => {
  const f = await fixture(t);
  const shell = await (await f.get('/api/orchestration/shell')).json();
  f.data.detail.entries[2].text = 'x'.repeat(400000);
  const response = await f.get(`/api/orchestration/threads/${shell.threads[0].id}`);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).thread.messages[2].text.length, 400000);
  const items = await readStream(f.ws(), 'orchestration.subscribeThread', {
    threadId: shell.threads[0].id, requestCompletionMarker: true,
  }, { count: 2 });
  assert.deepEqual(items.map(i => i.kind), ['snapshot', 'synchronized']);
  assert.equal(items[0].snapshot.thread.messages[2].text.length, 400000);
});

test('mobile text sends are accepted once across reconnects, reconcile pending IDs and update order keys', async t => {
  const f = await fixture(t);
  const shell = await (await f.get('/api/orchestration/shell')).json();
  const input = { type: 'thread.turn.start', commandId: 'send-once', threadId: shell.threads[0].id,
    message: { messageId: 'mobile-pending-id', role: 'user', text: ' new question ', attachments: [] } };
  const results = await Promise.all([call(f.ws(), 'orchestration.dispatchCommand', input), call(f.ws(), 'orchestration.dispatchCommand', input)]);
  assert.deepEqual(results[0], results[1]);
  assert.equal(f.requests.filter(r => r.method === 'session.send').length, 1);
  const detail = await (await f.get(`/api/orchestration/threads/${input.threadId}`)).json();
  assert.equal(detail.thread.messages.at(-1).id, input.message.messageId);
  assert.equal(detail.thread.messages.at(-1).text, 'new question');
  const updated = await (await f.get('/api/orchestration/shell')).json();
  assert(updated.threads[0].activeOrderKey < shell.threads[0].activeOrderKey);
  await assert.rejects(call(f.ws(), 'orchestration.dispatchCommand', { ...input,
    message: { ...input.message, text: 'different' } }), e => e._tag === 'OrchestrationDispatchCommandError');
  assert.equal(f.requests.filter(r => r.method === 'session.send').length, 1);
});

test('catalog-only mobile send uses catalog paths and inline images, never caller paths', async t => {
  const f = await fixture(t);
  f.data.catalog.runtimes = [];
  const shell = await (await f.get('/api/orchestration/shell')).json();
  await call(f.ws(), 'orchestration.dispatchCommand', { type: 'thread.turn.start', commandId: 'image-send',
    threadId: shell.threads[0].id, message: { messageId: 'image-message', role: 'user', text: '', attachments: [
      { type: 'image', mimeType: 'image/png', name: '../../private', sizeBytes: 3, dataUrl: 'data:image/png;base64,YWJj' },
    ] } });
  const send = f.requests.find(r => r.method === 'session.send');
  assert.equal(send.target, undefined);
  assert.equal(send.sessionPath, '/saved/a.jsonl');
  assert.deepEqual(send.images, [{ mimeType: 'image/png', data: 'YWJj' }]);
  assert(!JSON.stringify(send).includes('../../private'));
});

test('unknown targets, unsupported uploads and busy send failures do not acknowledge success', async t => {
  const f = await fixture(t);
  const shell = await (await f.get('/api/orchestration/shell')).json();
  const input = { type: 'thread.turn.start', commandId: 'rejected', threadId: shell.threads[0].id,
    message: { messageId: 'pending', role: 'user', text: 'hello', attachments: [] } };
  for (const bad of [ { ...input, threadId: '/caller/file' },
    { ...input, message: { ...input.message, attachments: [{ type: 'image', url: 'file:///private/file' }] } } ]) {
    await assert.rejects(call(f.ws(), 'orchestration.dispatchCommand', bad), e => e._tag === 'OrchestrationDispatchCommandError');
  }
  assert.equal(f.requests.filter(r => r.method === 'session.send').length, 0);
  f.data.rejectSend = true;
  const retry = { ...input, commandId: 'uncertain' };
  await assert.rejects(call(f.ws(), 'orchestration.dispatchCommand', retry));
  await assert.rejects(call(f.ws(), 'orchestration.dispatchCommand', retry));
  assert.equal(f.requests.filter(r => r.method === 'session.send').length, 1);
});

test('resume always returns a fresh fallback snapshot and completion marker', async t => {
  const f = await fixture(t);
  const values = await readStream(f.ws(), 'orchestration.subscribeShell', { afterSequence: 9_000_000_000_000_000, requestCompletionMarker: true }, { count: 2 });
  assert.equal(values[0].kind, 'snapshot');
  assert.equal(values[1].kind, 'synchronized');
});

// Mirrors the original client shell.ts: authoritative HTTP load, followed by
// cursor resume and completion marker. Decode with unchanged upstream contracts.
for (const empty of [false, true]) test(`stock client HTTP-to-shell resume completes (${empty ? 'empty' : 'populated'} catalog)`, async t => {
  const f = await fixture(t);
  if (empty) f.data.catalog = { projects: [], runtimes: [] };
  const response = await f.get('/api/orchestration/shell');
  assert.equal(response.status, 200);
  const initial = validateShell(await response.json());
  const input = validateShellInput({ afterSequence: initial.snapshotSequence, requestCompletionMarker: true });
  const items = await readStream(f.ws(), 'orchestration.subscribeShell', input, { count: 2 });
  const decoded = items.map(item => validateShellItem(item));
  assert.deepEqual(decoded.map(item => item.kind), ['snapshot', 'synchronized']);
  assert.deepEqual(decoded[0].snapshot.threads, initial.threads);
  assert.equal(items[0].snapshot.threads.length, empty ? 0 : 1);
});

test('failed HTTP load falls back to an authoritative socket snapshot', async t => {
  const f = await fixture(t);
  const good = structuredClone(f.data.catalog);
  f.data.catalog = { projects: null, runtimes: [] };
  assert.equal((await f.get('/api/orchestration/shell')).status, 503);
  f.data.catalog = good;
  const items = await readStream(f.ws(), 'orchestration.subscribeShell',
    validateShellInput({ requestCompletionMarker: true }), { count: 2 });
  items.forEach(validateShellItem);
  assert.deepEqual(items.map(item => item.kind), ['snapshot', 'synchronized']);
  assert.equal(items[0].snapshot.threads.length, 1);
});

test('saved history remains readable after runtime reuse without routing to the replacement', async t => {
  const f = await fixture(t);
  const shell = await (await f.get('/api/orchestration/shell')).json();
  const id = shell.threads[0].id;
  f.data.savedDetail = structuredClone(f.data.detail);
  f.data.detail.entries[0].text = 'replacement conversation';
  f.data.catalog.runtimes[0].path = '/saved/b.jsonl';
  f.requests.length = 0;
  const response = await f.get(`/api/orchestration/threads/${id}`);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).thread.messages[0].text, 'hello');
  const read = f.requests.find(r => r.method === 'session.read');
  assert.equal(read.target, undefined);
  assert.equal(read.sessionPath, '/saved/a.jsonl');
  assert.equal(read.projectPath, '/project');
  assert.equal((await f.get('/api/orchestration/threads/not-a-path')).status, 503);
});

test('read scope is required over HTTP and RPC, even for a valid device ticket', async t => {
  const f = await fixture(t, ['terminal:operate']);
  assert.equal((await f.get('/api/orchestration/shell')).status, 403);
  await assert.rejects(readStream(f.ws(), 'orchestration.subscribeShell', {}), error => error._tag === 'EnvironmentAuthorizationError');
  assert.equal(f.requests.length, 0);
});

test('HTTP rechecks authorization after a delayed desktop read', async t => {
  const f = await fixture(t);
  f.data.block = true;
  const response = f.get('/api/orchestration/shell');
  const deadline = Date.now() + 1000;
  while (!f.requests.length) {
    if (Date.now() > deadline) throw new Error('No catalog request');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
  f.store.revoke(f.session.sessionId);
  f.gateway.receive({ id: f.requests[0].id, result: f.data.catalog });
  const result = await response;
  assert.equal(result.status, 401);
  assert.equal((await result.json()).projects, undefined);
});

test('revoking a live subscription interrupts delivery and stops background reads', async t => {
  const f = await fixture(t);
  const started = Date.now();
  await assert.rejects(readStream(f.ws(), 'orchestration.subscribeShell', {}, {
    count: 100, onItem: () => f.store.revoke(f.session.sessionId),
  }));
  assert(Date.now() - started < 2000);
  const reads = f.requests.length;
  await new Promise(resolve => setTimeout(resolve, 600));
  assert.equal(f.requests.length, reads);
});

test('oversized snapshots fail without partial transcript content', async t => {
  const f = await fixture(t);
  const shell = await (await f.get('/api/orchestration/shell')).json();
  f.data.detail.entries[2].text = 'secret'.repeat(1500000);
  const response = await f.get(`/api/orchestration/threads/${shell.threads[0].id}`);
  assert.equal(response.status, 503);
  assert(!JSON.stringify(await response.json()).includes('secret'));
});

test('unimplemented pagination is rejected instead of silently truncating history', async t => {
  const f = await fixture(t);
  const shell = await (await f.get('/api/orchestration/shell')).json();
  const id = shell.threads[0].id;
  assert.equal((await f.get(`/api/orchestration/threads/${id}?turnLimit=1`)).status, 400);
  await assert.rejects(readStream(f.ws(), 'orchestration.subscribeThread', { threadId: id, turnLimit: 1 }));
});

test('sequence watermark and IDs survive restart; corrupt/symlink clocks fail closed', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'pimac-projection-clock-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'clock.json'), data = source();
  const config = { environmentId: 'environment-1', clockFile: file, request: async () => data.catalog };
  const first = new WorkspaceProjection(config);
  const a = await first.shellSnapshot(); first.close();
  const second = new WorkspaceProjection(config);
  const b = await second.shellSnapshot(); second.close();
  assert.equal(a.threads[0].id, b.threads[0].id);
  assert(b.snapshotSequence > a.snapshotSequence);
  await writeFile(file, '{bad');
  assert.throws(() => new WorkspaceProjection(config));
  await rm(file); await symlink(join(dir, 'target'), file);
  // A dangling symlink must be rejected as well.
  assert.throws(() => new WorkspaceProjection(config));
});

test('subscription interruption cleans up polling; initial completion stays paired with its snapshot', async () => {
  const data = source();
  let reads = 0;
  const workspace = new WorkspaceProjection({ environmentId: 'test', request: async () => { reads++; return data.catalog; }, intervalMs: 10 });
  const batches = [];
  const stop = workspace.watch('shell', { requestCompletionMarker: true }, batch => batches.push(batch), assert.fail);
  await new Promise(resolve => setTimeout(resolve, 30)); stop();
  assert.deepEqual(batches[0].map(item => item.kind), ['snapshot', 'synchronized']);
  assert.equal(workspace.watchers.size, 0);
  const count = reads;
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(reads, count); workspace.close();
});

test('interrupting an in-flight send cancels only its private submission intent', async () => {
  const sent = [];
  const ipc = createWorkspaceIPC(message => sent.push(message));
  const controller = new AbortController();
  const pending = ipc.request('session.send', { commandId: 'private-command', text: 'hello' }, { signal: controller.signal });
  const rejected = assert.rejects(pending, /interrupted/);
  controller.abort();
  await rejected;
  assert.deepEqual(sent.map(m => m.method), ['session.send', 'session.cancelSend']);
  assert.equal(sent[1].commandId, 'private-command');
  assert.notEqual(sent[0].id, sent[1].id);
  ipc.close();
});

test('private reads have deadlines, generated IDs and bounded capacity', async () => {
  const sent = [];
  const ipc = createWorkspaceIPC(m => sent.push(m), { timeoutMs: 10, maxPending: 1 });
  const first = ipc.request('workspace.catalog', { id: 'forged' });
  assert.notEqual(sent[0].id, 'forged');
  await assert.rejects(ipc.request('workspace.catalog'));
  ipc.receive({ id: 'wrong', result: {} });
  await assert.rejects(first);
  const pending = ipc.request('workspace.catalog'); ipc.close(); await assert.rejects(pending);
});
