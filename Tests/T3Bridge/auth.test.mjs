import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { once } from 'node:events';
import net from 'node:net';
import { AuthStore } from '../../Sources/PiMacApp/Resources/t3-bridge/auth-store.mjs';
import { createGateway } from '../../Sources/PiMacApp/Resources/t3-bridge/gateway.mjs';
import { TOKEN_EXCHANGE_GRANT, ACCESS_TOKEN_TYPE, BOOTSTRAP_TOKEN_TYPE, DEFAULT_SCOPES } from '../../Sources/PiMacApp/Resources/t3-bridge/protocol.mjs';

const adminToken = 'cd'.repeat(32);
function exchangeInput(credential, extra = {}) {
  return { grant_type: TOKEN_EXCHANGE_GRANT, subject_token: credential,
    subject_token_type: BOOTSTRAP_TOKEN_TYPE, requested_token_type: ACCESS_TOKEN_TYPE, ...extra };
}
function paired(store, scopes) {
  const grant = store.createPairing({ scopes });
  const result = store.exchange(exchangeInput(grant.credential));
  return { result, session: store.authenticate(`Bearer ${result.access_token}`), grant };
}
function stateFile(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'pimac-t3-auth-'));
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }));
  return path.join(directory, 'auth.json');
}
async function fixture(t, store = new AuthStore()) {
  const gateway = createGateway({ token: adminToken, authStore: store, send() {} });
  gateway.server.listen(0, '127.0.0.1');
  await once(gateway.server, 'listening');
  t.after(() => gateway.close());
  const base = `http://127.0.0.1:${gateway.server.address().port}`;
  const request = (route, { method = 'GET', token, data, form, headers = {} } = {}) => fetch(base + route, {
    method, headers: { ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(form ? { 'content-type': 'application/x-www-form-urlencoded' } : data !== undefined ? { 'content-type': 'application/json' } : {}),
      ...headers }, body: form ?? (data === undefined ? undefined : JSON.stringify(data)),
  });
  return { gateway, base, request, store };
}

test('one-time grants cannot be replayed; invalid scopes do not burn a grant', () => {
  const store = new AuthStore();
  const grant = store.createPairing();
  assert.throws(() => store.exchange(exchangeInput(grant.credential, { scope: 'access:write' })), e => e.body.reason === 'scope_not_granted');
  assert.throws(() => store.exchange(exchangeInput(grant.credential, { scope: 'made:up' })), e => e.body.reason === 'invalid_scope');
  const result = store.exchange(exchangeInput(grant.credential, { scope: 'orchestration:read' }));
  assert.equal(result.scope, 'orchestration:read');
  assert.throws(() => store.exchange(exchangeInput(grant.credential)), e => e.status === 401);
  assert.equal(store.clients().length, 1);
});

test('grant, device and ticket expiry are enforced, tickets are single-use', () => {
  let now = 1_000_000;
  const store = new AuthStore({ now: () => now, pairingTtlMs: 100, sessionTtlMs: 1000, ticketTtlMs: 50 });
  const expired = store.createPairing();
  now += 101;
  assert.throws(() => store.exchange(exchangeInput(expired.credential)));
  const { session, result } = paired(store);
  const ticket = store.createTicket(session);
  assert.equal(store.consumeTicket(ticket.ticket).sessionId, session.sessionId);
  assert.throws(() => store.consumeTicket(ticket.ticket));
  const expiring = store.createTicket(session);
  now += 51;
  assert.throws(() => store.consumeTicket(expiring.ticket));
  now += 1000;
  assert.throws(() => store.authenticate(`Bearer ${result.access_token}`));
  assert.deepEqual(store.clients(), []);
});

test('device revocation invalidates its outstanding tickets and survives restart', t => {
  const file = stateFile(t);
  const store = new AuthStore({ file });
  const { result, session } = paired(store);
  const ticket = store.createTicket(session);
  assert.equal(store.revoke(session.sessionId), true);
  assert.throws(() => store.authenticate(`Bearer ${result.access_token}`));
  assert.throws(() => store.consumeTicket(ticket.ticket));
  assert.throws(() => new AuthStore({ file }).authenticate(`Bearer ${result.access_token}`));
  assert.equal(store.revoke(session.sessionId), false);
});

test('persistence stores hashes only and keeps stable environment identity', t => {
  const file = stateFile(t);
  const store = new AuthStore({ file });
  const { result, session, grant } = paired(store);
  const ticket = store.createTicket(session);
  const contents = fs.readFileSync(file, 'utf8');
  for (const secret of [result.access_token, grant.credential, ticket.ticket]) assert.ok(!contents.includes(secret));
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(file)).mode & 0o777, 0o700);
  const restarted = new AuthStore({ file });
  assert.equal(restarted.state.environmentId, store.state.environmentId);
  assert.equal(restarted.authenticate(`Bearer ${result.access_token}`).sessionId, session.sessionId);
  assert.throws(() => restarted.consumeTicket(ticket.ticket));
  assert.deepEqual(restarted.pairingLinks(), []);
});

test('invalid or symlink state fails startup without overwriting', t => {
  const file = stateFile(t);
  fs.writeFileSync(file, '{broken');
  assert.throws(() => new AuthStore({ file }));
  assert.equal(fs.readFileSync(file, 'utf8'), '{broken');
  const link = file + '.link';
  fs.symlinkSync(file, link);
  assert.throws(() => new AuthStore({ file: link }));
});

test('pairing lists never leak credentials; revoked links cannot exchange', () => {
  const store = new AuthStore();
  const grant = store.createPairing({ label: 'My phone' });
  assert.ok(!JSON.stringify(store.pairingLinks()).includes(grant.credential));
  assert.equal(store.revokePairing(grant.id), true);
  assert.throws(() => store.exchange(exchangeInput(grant.credential)));
});

test('native mobile bootstrap request shape matches upstream client sequence', async t => {
  const { request } = await fixture(t);
  const descriptorResponse = await request('/.well-known/t3/environment');
  const descriptor = await descriptorResponse.json();
  assert.equal(descriptor.orchestrationProtocolVersion, 1);
  assert.equal(descriptor.capabilities.repositoryIdentity, false);
  assert.ok(descriptor.environmentId);
  const noSession = await (await request('/api/auth/session')).json();
  assert.equal(noSession.authenticated, false);
  assert.deepEqual(noSession.auth.sessionMethods, ['bearer-access-token']);
  assert.equal((await request('/internal/auth/pairing', { method: 'POST', data: {} })).status, 401);
  const grant = await (await request('/internal/auth/pairing', { method: 'POST', token: adminToken, data: {} })).json();
  // Same form fields and metadata as packages/client-runtime/src/authorization/remote.test.ts.
  const form = new URLSearchParams(exchangeInput(grant.credential, {
    client_label: 'T3 Code Mobile', client_device_type: 'mobile', client_os: 'iOS',
    scope: DEFAULT_SCOPES.join(' '),
  })).toString();
  const tokenResponse = await request('/oauth/token', { method: 'POST', form });
  assert.equal(tokenResponse.status, 200);
  assert.equal(tokenResponse.headers.get('cache-control'), 'no-store');
  const access = await tokenResponse.json();
  assert.equal(access.token_type, 'Bearer');
  const session = await (await request('/api/auth/session', { token: access.access_token })).json();
  assert.equal(session.authenticated, true);
  assert.equal(session.sessionMethod, 'bearer-access-token');
  const ticket = await (await request('/api/auth/websocket-ticket', { method: 'POST', token: access.access_token })).json();
  assert.equal(typeof ticket.ticket, 'string');
  assert.ok(Date.parse(ticket.expiresAt));
  const clients = await (await request('/internal/auth/clients', { token: adminToken })).json();
  assert.equal(clients[0].client.deviceType, 'mobile');
  assert.equal(clients[0].client.os, 'iOS');
  // T3 device credentials are not private workspace/admin credentials.
  assert.equal((await request('/internal/request', { method: 'POST', token: access.access_token, data: { method: 'workspace.snapshot' } })).status, 401);
  assert.equal((await request('/api/auth/clients', { token: access.access_token })).status, 403);
  assert.equal((await request('/api/auth/websocket-ticket', { method: 'POST', token: adminToken })).status, 401);
});

test('DPoP, malformed forms and browser Origins cannot consume grants', async t => {
  const { request, store } = await fixture(t);
  const grant = store.createPairing();
  const form = new URLSearchParams(exchangeInput(grant.credential)).toString();
  assert.equal((await request('/oauth/token', { method: 'POST', form, headers: { dpop: 'fake' } })).status, 401);
  assert.equal((await request('/oauth/token', { method: 'POST', form: form + '&subject_token=duplicate' })).status, 400);
  assert.equal((await request('/oauth/token', { method: 'POST', form, headers: { origin: 'https://evil.example' } })).status, 403);
  assert.equal((await request('/oauth/token', { method: 'POST', form })).status, 200);
  const replay = await request('/oauth/token', { method: 'POST', form });
  assert.equal(replay.status, 401);
  assert.equal((await replay.json())._tag, 'EnvironmentAuthInvalidError');
});

test('delegation requires administrative scopes and cannot escalate', async t => {
  const { request, store } = await fixture(t);
  const { result } = paired(store, ['access:write']);
  const response = await request('/api/auth/pairing-token', {
    method: 'POST', token: result.access_token, data: { scopes: ['orchestration:operate'] },
  });
  assert.equal(response.status, 400);
  assert.equal((await response.json()).reason, 'scope_not_granted');
  const narrow = await request('/api/auth/pairing-token', {
    method: 'POST', token: result.access_token, data: { scopes: ['access:write'] },
  });
  assert.equal(narrow.status, 200);
});

test('administrative revocation cannot revoke itself and invalidates other devices', async t => {
  const { request, store } = await fixture(t);
  const admin = paired(store, [...DEFAULT_SCOPES, 'access:read', 'access:write']);
  const peer = paired(store);
  const ticket = store.createTicket(peer.session);
  const own = await request('/api/auth/clients/revoke', {
    method: 'POST', token: admin.result.access_token, data: { sessionId: admin.session.sessionId },
  });
  assert.equal(own.status, 403);
  const clients = await (await request('/api/auth/clients', { token: admin.result.access_token })).json();
  assert.equal(clients.filter(c => c.current).length, 1);
  assert.ok(!JSON.stringify(clients).includes(peer.result.access_token));
  const response = await request('/api/auth/clients/revoke-others', {
    method: 'POST', token: admin.result.access_token,
  });
  assert.deepEqual(await response.json(), { revokedCount: 1 });
  assert.throws(() => store.authenticate(`Bearer ${peer.result.access_token}`));
  assert.throws(() => store.consumeTicket(ticket.ticket));
  assert.equal(store.authenticate(`Bearer ${admin.result.access_token}`).sessionId, admin.session.sessionId);
});

test('incompatible WebSocket upgrade fails explicitly rather than hanging', async t => {
  const { base } = await fixture(t);
  const endpoint = new URL(base);
  const socket = net.connect(Number(endpoint.port), endpoint.hostname);
  t.after(() => socket.destroy());
  await once(socket, 'connect');
  socket.write('GET /ws?wsTicket=invalid HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n');
  const [data] = await once(socket, 'data', { signal: AbortSignal.timeout(2000) });
  assert.match(data.toString(), /^HTTP\/1.1 409 /);
});

test('failed revocation persistence disables old credentials until restart', () => {
  const store = new AuthStore();
  const { session, result } = paired(store);
  const ticket = store.createTicket(session);
  store.persist = () => { throw new Error('disk full'); };
  assert.throws(() => store.revoke(session.sessionId));
  assert.throws(() => store.authenticate(`Bearer ${result.access_token}`));
  assert.throws(() => store.consumeTicket(ticket.ticket));
  assert.throws(() => store.createPairing());
});

test('no session is issued if durable commit fails', () => {
  const store = new AuthStore();
  const grant = store.createPairing();
  store.persist = () => { throw new Error('disk full'); };
  assert.throws(() => store.exchange(exchangeInput(grant.credential)));
  assert.equal(store.state.sessions.length, 0);
});
