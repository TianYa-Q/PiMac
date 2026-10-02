import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { cp, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
import { createGateway } from '../../Sources/PiMacApp/Resources/t3-bridge/gateway.mjs';
import { AuthStore } from '../../Sources/PiMacApp/Resources/t3-bridge/auth-store.mjs';
import { TOKEN_EXCHANGE_GRANT, BOOTSTRAP_TOKEN_TYPE, ACCESS_TOKEN_TYPE } from '../../Sources/PiMacApp/Resources/t3-bridge/protocol.mjs';
import { probe, call, WebSocket } from '../../sidecars/t3-rpc/test-client.mjs';

function paired(store) {
  const grant = store.createPairing();
  const result = store.exchange({ grant_type: TOKEN_EXCHANGE_GRANT, subject_token: grant.credential,
    subject_token_type: BOOTSTRAP_TOKEN_TYPE, requested_token_type: ACCESS_TOKEN_TYPE });
  return store.authenticate(`Bearer ${result.access_token}`);
}
async function fixture(t, options = {}) {
  const store = new AuthStore(options);
  const session = paired(store);
  const dispatched = [];
  const gateway = createGateway({ token: 'ab'.repeat(32), authStore: store,
    send: message => dispatched.push(message) });
  gateway.server.listen(0, '127.0.0.1');
  await once(gateway.server, 'listening');
  t.after(() => gateway.close());
  const base = `ws://127.0.0.1:${gateway.server.address().port}/ws`;
  const url = () => `${base}?orchestrationProtocol=1&wsTicket=${store.createTicket(session).ticket}`;
  return { store, session, gateway, base, url, dispatched };
}
async function connect(t, url, headers) {
  const ws = new WebSocket(url, { headers });
  t.after(() => ws.terminate());
  await once(ws, 'open', { signal: AbortSignal.timeout(2000) });
  return ws;
}
async function rejected(url, status, headers) {
  const ws = new WebSocket(url, { headers });
  const actual = await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { ws.terminate(); reject(new Error('Upgrade hung')); }, 2000);
    ws.on('error', () => {});
    ws.on('open', () => { clearTimeout(timer); ws.terminate(); reject(new Error('Unauthorized upgrade accepted')); });
    ws.on('unexpected-response', (_req, res) => { clearTimeout(timer); resolve(res.statusCode); res.resume(); ws.terminate(); });
  });
  assert.equal(actual, status);
}
function receive(ws) { return once(ws, 'message', { signal: AbortSignal.timeout(2000) }).then(([data]) => JSON.parse(data.toString())); }

// Both ends execute the pinned upstream RpcSerialization JSON and real RPC codecs.
test('real Effect client probes concurrently over authenticated WebSocket', async t => {
  const { url, dispatched } = await fixture(t);
  assert.deepEqual(await probe(url(), 5), [{}, {}, {}, {}, {}]);
  assert.deepEqual(dispatched, []);
});

test('tickets are single-use on network upgrade and fresh tickets reconnect', async t => {
  const { url } = await fixture(t);
  const used = url();
  assert.deepEqual(await probe(used), [{}]);
  await rejected(used, 401);
  assert.deepEqual(await probe(url()), [{}]);
});

test('bad paths, origins, conflicting auth and protocol versions do not burn tickets', async t => {
  const { url } = await fixture(t);
  const valid = url();
  await rejected(valid.replace('/ws?', '/other?'), 404);
  await rejected(valid.replace('orchestrationProtocol=1', 'orchestrationProtocol=2'), 409);
  await rejected(valid, 403, { Origin: 'https://evil.example' });
  await rejected(valid, 403, { Authorization: `Bearer ${'ab'.repeat(32)}` });
  await rejected(valid, 403, { DPoP: 'unsupported' });
  await rejected(valid, 403, { Cookie: 'pimac_t3_session=anything' });
  await rejected(valid + '&wsTicket=duplicate', 401);
  assert.deepEqual(await probe(valid), [{}]);
});

test('missing, expired and revoked tickets fail before any RPC dispatch', async t => {
  let now = Date.now();
  const { store, session, base, url, dispatched } = await fixture(t, { now: () => now });
  await rejected(`${base}?orchestrationProtocol=1`, 401);
  const expired = url();
  now += 31_000;
  await rejected(expired, 401);
  const revoked = url();
  store.revoke(session.sessionId);
  await rejected(revoked, 401);
  assert.deepEqual(dispatched, []);
});

test('device revocation closes every active socket and updates connection metadata', async t => {
  const { store, session, url } = await fixture(t);
  const first = await connect(t, url());
  const second = await connect(t, url());
  assert.equal(store.clients().find(s => s.sessionId === session.sessionId).connected, true);
  const closeFirst = once(first, 'close', { signal: AbortSignal.timeout(2000) });
  const closeSecond = once(second, 'close', { signal: AbortSignal.timeout(2000) });
  store.revoke(session.sessionId);
  assert.equal((await closeFirst)[0], 1008);
  assert.equal((await closeSecond)[0], 1008);
  // Client close may precede the server's close event/bookkeeping.
  const deadline = Date.now() + 1000;
  while (store.connections.size && Date.now() < deadline) await new Promise(resolve => setTimeout(resolve, 5));
  assert.equal(store.connections.size, 0);
});

test('failed durable revocation also closes active credentials (fail closed)', async t => {
  const { store, session, url } = await fixture(t);
  const ws = await connect(t, url());
  const closed = once(ws, 'close', { signal: AbortSignal.timeout(2000) });
  store.persist = () => { throw new Error('disk full'); };
  assert.throws(() => store.revoke(session.sessionId));
  assert.equal((await closed)[0], 1008);
});

test('live device expiry closes an idle connection', async t => {
  const { url } = await fixture(t, { sessionTtlMs: 250 });
  const ws = await connect(t, url());
  const [code] = await once(ws, 'close', { signal: AbortSignal.timeout(2000) });
  assert.equal(code, 1008);
});

test('Effect heartbeat works and unknown mutations never reach Swift', async t => {
  const { url, dispatched } = await fixture(t);
  const ws = await connect(t, url());
  let response = receive(ws);
  ws.send(JSON.stringify({ _tag: 'Ping' }));
  assert.deepEqual(await response, { _tag: 'Pong' });
  response = receive(ws);
  ws.send(JSON.stringify({ _tag: 'Request', id: '42', tag: 'orchestration.dispatchCommand', payload: {}, headers: [] }));
  const reply = await response;
  assert.equal(reply._tag, 'Exit');
  assert.equal(reply.requestId, '42');
  assert.equal(reply.exit._tag, 'Failure');
  assert.match(JSON.stringify(reply), /OrchestrationDispatchCommandError/);
  // A rejected write must not poison the socket or its request-capacity ledger.
  response = receive(ws);
  ws.send(JSON.stringify({ _tag: 'Request', id: '43', tag: 'server.probe', payload: {}, headers: [] }));
  assert.equal((await response).exit._tag, 'Success');
  response = receive(ws);
  ws.send(JSON.stringify({ _tag: 'Ping' }));
  assert.deepEqual(await response, { _tag: 'Pong' });
  assert.deepEqual(dispatched, []);
});

test('real Effect client receives a typed invalid-command refusal, never a false send acknowledgement', async t => {
  const { url, dispatched } = await fixture(t);
  for (const attachments of [[], [{ type: 'image', data: 'not-uploaded' }]]) {
    await assert.rejects(call(url(), 'orchestration.dispatchCommand', {
      type: 'thread.turn.start', commandId: 'send-test', threadId: 'existing', bootstrap: { createThread: {} },
      message: { messageId: 'pending', role: 'user', text: 'hello', attachments },
    }), error => error._tag === 'OrchestrationDispatchCommandError' && /No message was sent/.test(error.message));
  }
  assert.deepEqual(dispatched, []);
});

test('dispatch refusal still checks operation scope', async t => {
  const { url, session, dispatched } = await fixture(t);
  session.scopes = ['orchestration:read'];
  await assert.rejects(call(url(), 'orchestration.dispatchCommand', {}),
    error => error._tag === 'EnvironmentAuthorizationError' && error.requiredScope === 'orchestration:operate');
  assert.deepEqual(dispatched, []);
});

test('malformed JSON and oversized payloads close without workspace dispatch', async t => {
  const { url, dispatched } = await fixture(t);
  for (const [payload, expected] of [['{broken', 1007], ['x'.repeat(12 * 1024 * 1024 + 1), 1009]]) {
    const ws = await connect(t, url());
    const closed = once(ws, 'close', { signal: AbortSignal.timeout(2000) });
    ws.send(payload);
    assert.equal((await closed)[0], expected);
  }
  assert.deepEqual(dispatched, []);
});

test('batched RPC floods close within the request budget', async t => {
  const { url, dispatched } = await fixture(t);
  const ws = await connect(t, url());
  const closed = once(ws, 'close', { signal: AbortSignal.timeout(2000) });
  ws.send(JSON.stringify(Array.from({ length: 129 }, () => ({ _tag: 'Ping' }))));
  assert.equal((await closed)[0], 1008);
  assert.deepEqual(dispatched, []);
});

test('connection cap rejects upgrades without consuming their tickets', async t => {
  const { url } = await fixture(t);
  const sockets = [];
  for (let i = 0; i < 16; i++) sockets.push(await connect(t, url()));
  const retry = url();
  await rejected(retry, 503);
  const closed = once(sockets[0], 'close');
  sockets[0].terminate();
  await closed;
  // Allow server-side close bookkeeping to run before retrying.
  await new Promise(resolve => setTimeout(resolve, 10));
  assert.deepEqual(await probe(retry), [{}]);
});

test('copied resource bundle needs no npm modules and EOF closes active RPC', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-t3-rpc-bundle-'));
  const resources = fileURLToPath(new URL('../../Sources/PiMacApp/Resources/t3-bridge', import.meta.url));
  await cp(resources, join(directory, 'bridge'), { recursive: true });
  const token = 'cd'.repeat(32);
  const child = spawn(process.execPath, [join(directory, 'bridge/gateway.mjs')], {
    cwd: directory, env: { ...process.env, PIMAC_T3_BRIDGE_TOKEN: token,
      PIMAC_T3_AUTH_FILE: join(directory, 'auth.json') }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  const exited = once(child, 'close');
  child.stderr.resume();
  child.stdin.on('error', () => {});
  const lines = createInterface({ input: child.stdout });
  t.after(async () => { child.kill('SIGKILL'); await exited; lines.close(); await rm(directory, { recursive: true, force: true }); });
  const [line] = await once(lines, 'line', { signal: AbortSignal.timeout(3000) }).catch(error => { throw new Error(`Bundle startup failed: exit=${child.exitCode}`, { cause: error }); });
  const { port } = JSON.parse(line);
  const base = `http://127.0.0.1:${port}`;
  const grant = await (await fetch(`${base}/internal/auth/pairing`, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, 'content-type': 'application/json' }, body: '{}',
  })).json();
  const result = await (await fetch(`${base}/oauth/token`, {
    method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({ grant_type: TOKEN_EXCHANGE_GRANT, subject_token: grant.credential,
      subject_token_type: BOOTSTRAP_TOKEN_TYPE, requested_token_type: ACCESS_TOKEN_TYPE }),
  })).json();
  const ticket = await (await fetch(`${base}/api/auth/websocket-ticket`, {
    method: 'POST', headers: { authorization: `Bearer ${result.access_token}` },
  })).json();
  const ws = await connect(t, `ws://127.0.0.1:${port}/ws?orchestrationProtocol=1&wsTicket=${ticket.ticket}`);
  const reply = receive(ws);
  ws.send(JSON.stringify({ _tag: 'Request', id: '1', tag: 'server.probe', payload: {}, headers: [] }));
  assert.equal((await reply).exit._tag, 'Success');
  const closed = once(ws, 'close', { signal: AbortSignal.timeout(3000) });
  child.stdin.end();
  await closed.catch(error => { throw new Error('Bundle EOF did not close RPC', { cause: error }); });
  const [code] = await exited;
  assert.equal(code, 0);
});

test('gateway shutdown terminates upgraded connections', async t => {
  const { url, gateway } = await fixture(t);
  const ws = await connect(t, url());
  const closed = once(ws, 'close', { signal: AbortSignal.timeout(2000) });
  gateway.close();
  await closed;
});
