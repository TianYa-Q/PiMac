import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import net from 'node:net';
import http from 'node:http';
import { randomUUID, createHash } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import WebSocket from 'ws';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';
import { call } from '../generated/client.mjs';

async function unusedPort() {
  const server = net.createServer();
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;
  await new Promise(resolve => server.close(resolve));
  return port;
}

function request(base, route, { method = 'GET', headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const req = http.request(base + route, { method, headers }, response => {
      const chunks = []; response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString() }));
      response.on('error', reject);
    });
    req.on('error', reject); req.end(body);
  });
}

test('opt-in LAN shares upstream DPoP/WS auth; controls and forwarding spoofing stay denied', { timeout: 30000 }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-lan-'));
  let gateway = await createServerGateway({ token: 'ab'.repeat(32), directory, piConfig: { enabled: false } });
  const originalServerURL = gateway.serverURL;
  t.after(async () => { await gateway.close(); await rm(directory, { recursive: true, force: true }); });
  assert.deepEqual(gateway.lan.status(), { endpoint: null });
  await assert.rejects(gateway.lan.configure({ host: '0.0.0.0', port: 1023 }));
  await assert.rejects(gateway.lan.configure({ host: '8.8.8.8', port: 3773 }));
  await assert.rejects(gateway.lan.configure({ host: '192.168.99.250', port: 3773 }));
  const endpoint = { host: '0.0.0.0', port: await unusedPort() };
  const base = `http://127.0.0.1:${endpoint.port}`;
  await new Promise(resolve => gateway.server.listen(0, '127.0.0.1', resolve));
  const supervisor = `http://127.0.0.1:${gateway.server.address().port}`;
  assert.equal((await request(supervisor, '/internal/auth/lan')).status, 401);
  const admin = (route, body) => request(supervisor, '/internal/auth/' + route, { method: 'POST', headers: {
    authorization: 'Bearer ' + 'ab'.repeat(32), 'content-type': 'application/json',
  }, body: JSON.stringify(body) });
  assert.equal((await admin('pairing', {})).status, 400, 'pairing requires explicit LAN activation');
  assert.equal((await admin('lan', { endpoint })).status, 200);
  assert.deepEqual(gateway.lan.status(), { endpoint });
  await gateway.lan.configure(endpoint); // idempotent; never restart Server
  assert.equal((await request(base, '/.well-known/t3/environment')).status, 200);
  assert.equal((await request(base, '/api/auth/websocket-ticket', { method: 'POST',
    headers: { 'content-type': 'application/json' }, body: '{}' })).status, 401);
  assert.equal((await request(base, '/.well-known/t3/environment', { headers: { host: 'attacker.invalid' } })).status, 403);
  assert.equal((await request(base, '/.well-known/t3/environment', { headers: { origin: base } })).status, 403);
  for (const path of ['/internal/auth/desktop-session', '/internal/auth/pairing', '/api/connect/unlink', '/api/connect/preferences']) {
    assert.equal((await request(base, path, { method: 'POST', body: '{}', headers: {
      authorization: 'Bearer ' + 'ab'.repeat(32), 'content-type': 'application/json',
      'x-pimac-control': gateway.official.broker.controlToken,
    } })).status, 403);
  }
  const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
  const jwk = await exportJWK(publicKey);
  const proof = (route, token, scheme = 'http', method = 'POST') => new SignJWT({
    htu: base.replace('http:', scheme + ':') + route.split('?')[0], htm: method, jti: randomUUID(),
    ...(token ? { ath: createHash('sha256').update(token).digest('base64url') } : {}),
  }).setProtectedHeader({ alg: 'ES256', typ: 'dpop+jwt', jwk }).setIssuedAt().sign(privateKey);
  const paired = await admin('pairing', {});
  assert.equal(paired.status, 200);
  const pairing = JSON.parse(paired.body);
  const exchanged = await request(base, '/oauth/token', { method: 'POST', headers: {
    'content-type': 'application/x-www-form-urlencoded', dpop: await proof('/oauth/token'),
    // The LAN proxy must strip these so DPoP continues validating against HTTP.
    'x-forwarded-proto': 'https', 'x-forwarded-host': 'attacker.invalid', forwarded: 'proto=https;host=attacker.invalid',
  }, body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap',
    requested_token_type: 'urn:ietf:params:oauth:token-type:access_token', subject_token: pairing.credential }).toString() });
  assert.equal(exchanged.status, 200, exchanged.body);
  const token = JSON.parse(exchanged.body).access_token;
  const mint = async (scheme = 'http') => request(base, '/api/auth/websocket-ticket', { method: 'POST', headers: {
    authorization: 'DPoP ' + token, dpop: await proof('/api/auth/websocket-ticket', token, scheme),
    'content-type': 'application/json', 'x-forwarded-proto': 'https',
  }, body: '{}' });
  assert.equal((await mint('https')).status, 401);
  const ticket = async () => { const r = await mint(); assert.equal(r.status, 200, r.body); return JSON.parse(r.body).ticket; };
  const wsURL = secret => base.replace('http:', 'ws:') + '/ws?orchestrationProtocol=2&wsTicket=' + secret;
  await call(wsURL(await ticket()), 'server.probe', {});
  // Earlier activity is HTTP (not WS): verify the LAN allowlist reaches upstream
  // handlers, while DPoP authentication and cursor validation remain enforced.
  const projectId = randomUUID();
  await call(wsURL(await ticket()), 'projects.mutate', {
    type: 'project.create', commandId: randomUUID(), projectId,
    title: 'History fixture', workspaceRoot: directory,
  });
  const { threadId } = await call(wsURL(await ticket()), 'orchestration.launchThread', {
    commandId: randomUUID(), projectId, title: 'History fixture',
    workspaceStrategy: { type: 'root' }, modelSelection: { instanceId: 'pi', model: 'test/model' },
    runtimeMode: 'full-access', interactionMode: 'default',
  });
  const readThread = async (suffix, authenticated = true) => {
    const route = `/api/orchestration/threads/${threadId}/${suffix}`;
    return request(base, route, { headers: {
      'x-t3-orchestration-protocol': '2',
      ...(authenticated ? { authorization: 'DPoP ' + token,
        dpop: await proof(route, token, 'http', 'GET') } : {}),
    } });
  };
  const bounded = await readThread('bounded');
  assert.equal(bounded.status, 200, bounded.body);
  assert.equal(JSON.parse(bounded.body).hasMoreHistory, false);
  const invalidHistory = await readThread('history?cursor=invalid');
  assert.equal(invalidHistory.status, 400, invalidHistory.body);
  assert.equal(JSON.parse(invalidHistory.body).reason, 'invalid_history_cursor');
  for (const suffix of ['bounded', 'history?cursor=invalid']) {
    assert.equal((await readThread(suffix, false)).status, 401);
  }
  await assert.rejects(call(wsURL(await ticket()), 'server.getProcessDiagnostics', {}),
    error => error._tag === 'EnvironmentAuthorizationError');
  const denied = new WebSocket(wsURL(await ticket()), { origin: 'http://attacker.invalid' });
  denied.on('error', () => {});
  await new Promise((resolve, reject) => {
    denied.once('open', () => { denied.terminate(); reject(new Error('Cross-origin WS accepted')); });
    denied.once('unexpected-response', (_, response) => {
      response.resume(); denied.terminate();
      try { assert.equal(response.statusCode, 403); resolve(); } catch (error) { reject(error); }
    });
  });
  const accepted = new WebSocket(wsURL(await ticket()), { origin: base });
  await new Promise((resolve, reject) => { accepted.once('open', resolve); accepted.once('error', reject); });
  // An occupied replacement must leave the existing LAN endpoint untouched.
  const blocker = net.createServer();
  await new Promise(resolve => blocker.listen(0, '0.0.0.0', resolve));
  await assert.rejects(gateway.lan.configure({ host: '127.0.0.1', port: blocker.address().port }), { code: 'EADDRINUSE' });
  await new Promise(resolve => blocker.close(resolve));
  assert.deepEqual(gateway.lan.status(), { endpoint });
  const disconnected = new Promise(resolve => accepted.once('close', resolve));
  assert.equal((await admin('lan', { endpoint: null })).status, 200);
  await disconnected;
  assert.deepEqual(gateway.lan.status(), { endpoint: null });
  assert.equal((await fetch(gateway.serverURL + '/.well-known/t3/environment')).status, 200);
  await gateway.lan.configure(endpoint);
  await call(wsURL(await ticket()), 'server.probe', {}); // existing phone grant remains valid
  await gateway.close();
  await assert.rejects(gateway.lan.configure(endpoint), /closed/);
  gateway = await createServerGateway({ token: 'ab'.repeat(32), directory,
    publicEndpoint: endpoint, piConfig: { enabled: false } });
  assert.equal(gateway.serverURL, originalServerURL, 'LAN never changes the saved Tunnel origin');
  await call(wsURL(await ticket()), 'server.probe', {}); // upstream grant survives an actual restart
});
