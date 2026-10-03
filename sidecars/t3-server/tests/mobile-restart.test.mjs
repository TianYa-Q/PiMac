import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import http from 'node:http';
import net from 'node:net';
import { randomUUID, createHash } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import * as DateTime from 'effect/DateTime';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';
import { call } from '../generated/client.mjs';

// Emulate TLS termination without contacting the relay or real phone accounts.
function request(base, route, headers, body) {
  return new Promise((resolve, reject) => {
    const req = http.request(base + route, { method: 'POST', headers: {
      host: 'restart.example.test', 'x-forwarded-proto': 'https', ...headers,
    } }, response => {
      const chunks = []; response.on('data', chunk => chunks.push(chunk));
      response.on('error', reject);
      response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks).toString()) }));
    });
    req.on('error', reject); req.end(body);
  });
}

test('phone DPoP credential and WebSocket reconnect survive repeated real Server restart', { timeout: 60000 }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-phone-restart-'));
  let gateway;
  t.after(async () => { await gateway?.close(); await rm(directory, { recursive: true, force: true }); });
  const open = () => createServerGateway({ token: 'ab'.repeat(32), directory, piConfig: { enabled: false } });
  gateway = await open();
  const originalURL = gateway.serverURL;
  const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
  const jwk = await exportJWK(publicKey);
  const proof = (route, token) => new SignJWT({
    htu: 'https://restart.example.test' + route, htm: 'POST', jti: randomUUID(),
    ...(token ? { ath: createHash('sha256').update(token).digest('base64url') } : {}),
  }).setProtectedHeader({ alg: 'ES256', typ: 'dpop+jwt', jwk }).setIssuedAt().sign(privateKey);
  const pairing = await gateway.official.management.pairing({ label: 'Restart phone' });
  const exchange = await request(originalURL, '/oauth/token', {
    'content-type': 'application/x-www-form-urlencoded', dpop: await proof('/oauth/token'),
  }, new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap',
    requested_token_type: 'urn:ietf:params:oauth:token-type:access_token', subject_token: pairing.credential }).toString());
  assert.equal(exchange.status, 200);
  const token = exchange.body.access_token;
  for (let n = 0; n < 3; n++) {
    assert.equal(gateway.serverURL, originalURL, 'Tunnel origin must remain identical');
    const ticket = await request(gateway.serverURL, '/api/auth/websocket-ticket', {
      authorization: 'DPoP ' + token, dpop: await proof('/api/auth/websocket-ticket', token),
      'content-type': 'application/json',
    }, '{}');
    assert.equal(ticket.status, 200, 'saved phone authorization must remain usable');
    await call(gateway.serverURL.replace('http:', 'ws:') + '/ws?orchestrationProtocol=2&wsTicket=' + ticket.body.ticket,
      'server.reportClientActivity', {
        clientId: 'restart-phone', clientKind: 'mobile', visible: true, focused: true,
        recentlyInteracted: true, scopes: [], observedAt: DateTime.nowUnsafe(),
      });
    await gateway.close(); gateway = null;
    if (n < 2) gateway = await open();
  }

  // A different process may take the saved port while Pi Mac is offline.
  // Recovery must choose a new port without dropping phone credentials or
  // mistaking that unrelated listener for the official Server.
  const owner = net.createServer();
  await new Promise((resolve, reject) => {
    owner.once('error', reject);
    owner.listen(Number(new URL(originalURL).port), '127.0.0.1', resolve);
  });
  t.after(() => new Promise(resolve => owner.close(resolve)));
  gateway = await open();
  assert.notEqual(gateway.serverURL, originalURL);
  assert.equal(owner.listening, true);
  const recoveredTicket = await request(gateway.serverURL, '/api/auth/websocket-ticket', {
    authorization: 'DPoP ' + token, dpop: await proof('/api/auth/websocket-ticket', token),
    'content-type': 'application/json',
  }, '{}');
  assert.equal(recoveredTicket.status, 200);
});
