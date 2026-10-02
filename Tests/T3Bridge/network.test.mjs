import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, rm, readFile, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createGateway } from '../../Sources/PiMacApp/Resources/t3-bridge/gateway.mjs';
import { validatePublicEndpoint, isPrivateAddress } from '../../Sources/PiMacApp/Resources/t3-bridge/network.mjs';
import { createReadDiagnostics } from '../../Sources/PiMacApp/Resources/t3-bridge/diagnostics.mjs';
import { acquireChildLease } from '../../Sources/PiMacApp/Resources/t3-bridge/child-lease.mjs';
import { AuthStore } from '../../Sources/PiMacApp/Resources/t3-bridge/auth-store.mjs';
import { TOKEN_EXCHANGE_GRANT, BOOTSTRAP_TOKEN_TYPE, ACCESS_TOKEN_TYPE } from '../../Sources/PiMacApp/Resources/t3-bridge/protocol.mjs';
import { call, readStream, probe, WebSocket } from '../../sidecars/t3-rpc/test-client.mjs';
import { encodeConfig, encodeConfigEvent, encodeLifecycle } from '../../sidecars/t3-rpc/generated/upstream-validation.mjs';
const token = 'ab'.repeat(32);
async function fixture(t) {
  const store = new AuthStore(), messages = [];
  let gateway;
  gateway = createGateway({ token, authStore: store, publicEndpoint: { host: '127.0.0.1', port: 3773 }, send: m => {
    messages.push(m); queueMicrotask(() => gateway.receive({ id: m.id, result: { projects: [], runtimes: [] } }));
  } });
  for (const server of [gateway.server, gateway.publicServer]) { server.listen(0, '127.0.0.1'); await once(server, 'listening'); }
  t.after(() => gateway.close());
  const base = `http://127.0.0.1:${gateway.publicServer.address().port}`;
  const local = `http://127.0.0.1:${gateway.server.address().port}`;
  const grant = store.createPairing();
  const response = store.exchange({ grant_type: TOKEN_EXCHANGE_GRANT, subject_token: grant.credential,
    subject_token_type: BOOTSTRAP_TOKEN_TYPE, requested_token_type: ACCESS_TOKEN_TYPE });
  const session = store.authenticate(`Bearer ${response.access_token}`);
  const ws = () => `${base.replace('http:', 'ws:')}/ws?orchestrationProtocol=1&wsTicket=${store.createTicket(session).ticket}`;
  return { gateway, store, messages, base, local, ws, access: response.access_token, session };
}

test('phone access is absent by default; only owned private IPv4 endpoints are accepted', () => {
  for (const host of ['10.1.2.3', '172.16.1.2', '192.168.1.2']) assert(isPrivateAddress(host));
  for (const host of ['0.0.0.0', '8.8.8.8', '127.0.0.1', '100.64.0.1', '100.65.1.2', '100.127.255.255', '100.128.0.1', 'localhost', '::1', '192.168.001.2']) assert(!isPrivateAddress(host));
  assert.throws(() => validatePublicEndpoint({ host: '192.168.1.2', port: 3773 }, {}));
  assert.throws(() => validatePublicEndpoint({ host: '0.0.0.0', port: 3773 }));
  assert.throws(() => validatePublicEndpoint({ host: '127.0.0.1', port: 80 }));
  const gateway = createGateway({ token, authStore: new AuthStore(), send: () => {} });
  assert.equal(gateway.publicServer, undefined); gateway.close();
});

test('read diagnostics distinguish HTTP, catalog and shell stream without exposing secrets', async t => {
  const f = await fixture(t);
  const url = f.local + '/internal/auth/read-diagnostics';
  const inspect = async () => (await fetch(url, { headers: { authorization: `Bearer ${token}` } })).json();
  assert.equal((await fetch(url)).status, 401);
  assert.equal((await fetch(url, { headers: { authorization: `Bearer ${f.access}` } })).status, 401);
  assert.equal((await fetch(f.base + '/internal/auth/read-diagnostics', { headers: { authorization: `Bearer ${token}` } })).status, 404);
  assert.equal((await inspect()).shellHttpRequests, 0);
  await fetch(f.base + '/api/orchestration/shell', { headers: { authorization: `Bearer ${f.access}` } });
  // This fixture has an empty catalog, which must still complete synchronization.
  await readStream(f.ws(), 'orchestration.subscribeShell', { requestCompletionMarker: true }, { count: 2 });
  const state = await inspect();
  assert.equal(state.shellHttpRequests, 1);
  assert.equal(state.shellHttpStatus, 200);
  assert(state.catalogReads >= 2);
  assert.equal(state.catalogFailures, 0);
  assert.equal(state.shellSubscriptions, 1);
  assert.equal(state.shellSnapshots, 1);
  assert.equal(state.shellCompletionMarkers, 1);
  assert.equal(state.lastRPC, 'orchestration.subscribeShell');
  assert(!JSON.stringify(state).includes(f.access));
  await fetch(f.base + '/api/orchestration/shell');
  assert.equal((await inspect()).shellHttpStatus, 401);
  assert.equal((await inspect()).lastFailure, 'shell_http_failed');
});

test('native binary JSON frames remain valid after Effect selects ArrayBuffer mode', { timeout: 5000 }, async t => {
  const f = await fixture(t);
  const ws = new WebSocket(f.ws());
  t.after(() => ws.terminate());
  await once(ws, 'open');
  // A client can send immediately, or after the scoped Effect server has started.
  for (let id = 1; id <= 2; id++) {
    const message = once(ws, 'message');
    ws.send(Buffer.from(JSON.stringify({ _tag: 'Request', id: String(id),
      tag: 'server.probe', payload: {}, headers: [] })));
    const [data] = await message;
    const frame = JSON.parse(data.toString());
    assert.equal(frame._tag, 'Exit');
    assert.equal(frame.exit._tag, 'Success');
  }
  const message = once(ws, 'message');
  ws.send(Buffer.from(JSON.stringify({ _tag: 'Request', id: 'shell',
    tag: 'orchestration.subscribeShell', payload: { requestCompletionMarker: true }, headers: [] })));
  const [data] = await message;
  const frame = JSON.parse(data.toString());
  assert.equal(frame._tag, 'Chunk');
  assert.equal(frame.values[0].kind, 'snapshot');
});

test('diagnostic allowlists never retain attacker strings or payloads', () => {
  const diagnostics = createReadDiagnostics();
  diagnostics.rpc('credential-secret');
  diagnostics.event('prompt-secret');
  diagnostics.catalogStarted(); diagnostics.catalogFailed();
  const state = diagnostics.snapshot();
  assert.equal(state.lastRPC, 'unsupported');
  assert.equal(state.lastFailure, 'catalog_read_failed');
  assert(!JSON.stringify(state).includes('secret'));
  state.lastRPC = 'mutated';
  assert.equal(diagnostics.snapshot().lastRPC, 'unsupported');
});

test('phone listener never exposes admin or diagnostic mutations, even with supervisor secret', async t => {
  const f = await fixture(t);
  for (const path of ['/internal/auth/pairing', '/internal/request', '/internal/auth/clients']) {
    const response = await fetch(f.base + path, { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' },
      body: JSON.stringify({ method: 'session.prompt', target: 'arbitrary', text: 'must not run' }) });
    assert.equal(response.status, 404);
  }
  const local = await fetch(f.local + '/internal/auth/pairing', { method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: '{}' });
  assert.equal(local.status, 200);
  assert.equal(f.messages.length, 0);
  assert.equal((await fetch(f.base + '/api/orchestration/shell')).status, 401);
  assert.equal((await fetch(f.base + '/api/orchestration/shell', { headers: { authorization: `Bearer ${f.access}` } })).status, 200);
});

test('real Effect client initializes config, settings and lifecycle without fake agent drivers', async t => {
  const f = await fixture(t);
  const config = await call(f.ws(), 'server.getConfig');
  const encoded = encodeConfig(config);
  assert.deepEqual(encoded.providers, []);
  assert.equal(encoded.threadSnapshotPagination, false);
  assert.equal(encoded.reasoningMessages, true);
  assert.equal(encoded.environment.environmentId, f.store.state.environmentId);
  assert.equal(encoded.settings.enableAgentBrowserAccess, false);
  const events = await readStream(f.ws(), 'subscribeServerConfig', { environmentThemes: true, usageLimitSources: true }, { count: 3 });
  for (const event of events) encodeConfigEvent(event);
  assert.deepEqual(events.map(e => e.type), ['snapshot', 'environmentThemesUpdated', 'usageLimitSourcesUpdated']);
  const lifecycle = await readStream(f.ws(), 'subscribeServerLifecycle', {}, { count: 2 });
  for (const event of lifecycle) encodeLifecycle(event);
  assert.deepEqual(lifecycle.map(e => e.type), ['welcome', 'ready']);
  await call(f.ws(), 'server.getSettings');
  assert.equal(f.messages.length, 0); // Initializing the client never starts another Pi.
});

test('native same-endpoint Origin is accepted; foreign or Host-spoofed Origin cannot consume tickets', async t => {
  const f = await fixture(t);
  const url = f.ws();
  const bad = new WebSocket(url, { headers: { Origin: 'https://evil.invalid', Host: 'evil.invalid' } });
  bad.on('error', () => {});
  const [response] = await once(bad, 'unexpected-response'); // first argument is request
  response.abort();
  const good = new WebSocket(url, { headers: { Origin: f.base } });
  good.on('error', () => {}); await once(good, 'open');
  const message = once(good, 'message');
  good.send(JSON.stringify({ _tag: 'Request', id: '1', tag: 'server.probe', payload: {}, headers: [] }));
  assert.equal(JSON.parse(String((await message)[0])).exit._tag, 'Success');
  good.close(); await once(good, 'close');
});

test('local revocation also terminates the phone listener socket', async t => {
  const f = await fixture(t), socket = new WebSocket(f.ws());
  socket.on('error', () => {}); await once(socket, 'open');
  const closed = once(socket, 'close');
  const response = await fetch(f.local + '/internal/auth/revoke-client', { method: 'POST',
    headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: JSON.stringify({ sessionId: f.session.sessionId }) });
  assert.equal(response.status, 200);
  assert.equal((await closed)[0], 1008);
});

test('outstanding RPC requests are bounded even when every handler is a never-ending subscription', async t => {
  const f = await fixture(t), socket = new WebSocket(f.ws());
  socket.on('error', () => {}); await once(socket, 'open');
  const closed = once(socket, 'close');
  for (let id = 0; id < 17; id++) socket.send(JSON.stringify({ _tag: 'Request', id: String(id),
    tag: id < 8 ? 'subscribeServerConfig' : 'server.getConfig', payload: {}, headers: [] }));
  const [code, reason] = await closed;
  assert.equal(code, 1008); assert.equal(String(reason), 'Request capacity exceeded');
});

test('child lifetime guard is exclusive, refuses symlinks and does not steal stale markers', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'pimac-child-guard-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const auth = join(dir, 'auth.json'), release = acquireChildLease(auth);
  assert.throws(() => acquireChildLease(auth));
  release(); const second = acquireChildLease(auth); second();
  await symlink(join(dir, 'missing'), join(dir, 'child-owner.json'));
  assert.throws(() => acquireChildLease(auth));
});

test('a replacement child cannot open the auth store until the old child actually exits', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'pimac-child-handoff-')); t.after(() => rm(dir, { recursive: true, force: true }));
  const entry = 'Sources/PiMacApp/Resources/t3-bridge/gateway.mjs';
  const env = { ...process.env, PIMAC_T3_BRIDGE_TOKEN: token, PIMAC_T3_AUTH_FILE: join(dir, 'auth.json') };
  delete env.PIMAC_T3_PUBLIC_HOST; delete env.PIMAC_T3_PUBLIC_PORT;
  const launch = () => spawn(process.execPath, [entry], { env, stdio: ['pipe', 'pipe', 'pipe'] });
  const first = launch(); first.stderr.resume(); t.after(() => { if (first.exitCode === null) first.kill(); });
  await once(first.stdout, 'data');
  const before = await readFile(env.PIMAC_T3_AUTH_FILE);
  const second = launch(); second.stderr.resume(); second.stdout.resume();
  assert.notEqual((await once(second, 'exit'))[0], 0);
  assert.deepEqual(await readFile(env.PIMAC_T3_AUTH_FILE), before);
  const ended = once(first, 'exit'); first.stdin.end(); assert.equal((await ended)[0], 0);
  const third = launch(); third.stderr.resume(); t.after(() => { if (third.exitCode === null) third.kill(); });
  await once(third.stdout, 'data'); const end = once(third, 'exit'); third.stdin.end(); assert.equal((await end)[0], 0);
});
