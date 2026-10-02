import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';
import WebSocket from 'ws';
import http from 'node:http';
import { originAllowed } from '../origin-policy.mjs';

test('Tunnel HTTPS Origin uses the forwarded scheme without relaxing cross-origin policy', () => {
  const headers = { host: 'tunnel.example.test', origin: 'https://tunnel.example.test',
    upgrade: 'websocket', 'x-forwarded-proto': 'https' };
  assert.equal(originAllowed('GET', '/ws?wsTicket=secret', headers), true);
  for (const origin of ['null', 'https://attacker.invalid', 'http://tunnel.example.test',
    'https://tunnel.example.test:444', 'https://user@tunnel.example.test', 'https://tunnel.example.test/path']) {
    assert.equal(originAllowed('GET', '/ws', { ...headers, origin }), false);
  }
  assert.equal(originAllowed('GET', '/ws', { ...headers, 'x-forwarded-proto': undefined }), false);
  assert.equal(originAllowed('POST', '/api/auth/websocket-ticket', headers), false);
  assert.equal(originAllowed('GET', '/ws', { ...headers, upgrade: undefined }), false);
  assert.equal(originAllowed('GET', '/ws', { host: '192.168.0.110:3773',
    origin: 'http://192.168.0.110:3773', upgrade: 'websocket' }), true);
});

test('removed LAN endpoint cannot be opened by gateway callers', async () => {
  await assert.rejects(createServerGateway({ token: 'ab'.repeat(32), directory: '/unused',
    publicEndpoint: { host: '192.168.1.2', port: 3773 } }), /LAN access has been removed/);
});

test('mobile HTTPS DPoP and WebSocket work with Cloudflare-style TLS termination', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-tunnel-'));
  const gateway = await createServerGateway({ token: 'ab'.repeat(32), directory,
    piConfig: { binaryPath: process.execPath, binaryArgs: [new URL('./fixtures/pi.mjs', import.meta.url).pathname] } });
  t.after(async () => { await gateway.close(); await rm(directory, { recursive: true, force: true }); });
  const publicBase = 'https://tunnel.example.test';
  const forwarded = { host: 'tunnel.example.test', 'x-forwarded-proto': 'https' };
  // Node fetch may replace Host; use raw HTTP to emulate cloudflared exactly.
  const request = (path, options = {}) => new Promise((resolve, reject) => {
    const req = http.request(gateway.serverURL + path, {
      method: options.method ?? 'GET', headers: { ...forwarded, ...options.headers },
    }, response => {
      const chunks = []; response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve(new Response(Buffer.concat(chunks), { status: response.statusCode })));
      response.on('error', reject);
    });
    req.on('error', reject); req.end(options.body?.toString());
  });
  const descriptor = await (await request('/.well-known/t3/environment')).json();
  assert.equal(descriptor.label, 'Pi Mac · Tunnel');
  const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
  const jwk = await exportJWK(publicKey);
  const proof = (url, accessToken) => new SignJWT({ htu: url, htm: 'POST', jti: randomUUID(),
    ...(accessToken ? { ath: createHash('sha256').update(accessToken).digest('base64url') } : {}) })
    .setProtectedHeader({ alg: 'ES256', typ: 'dpop+jwt', jwk }).setIssuedAt().sign(privateKey);
  // Fixture bootstrap: real relay-issued credentials require account/device acceptance.
  const pairing = await gateway.official.management.pairing({ label: 'Phone fixture' });
  const exchange = await request('/oauth/token', { method: 'POST', headers: {
    'content-type': 'application/x-www-form-urlencoded', dpop: await proof(publicBase + '/oauth/token'),
  }, body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap',
    requested_token_type: 'urn:ietf:params:oauth:token-type:access_token', subject_token: pairing.credential }) });
  const credential = await exchange.json();
  assert.equal(exchange.status, 200, JSON.stringify(credential));
  assert.equal(credential.token_type, 'DPoP');
  const mintTicket = async (url = publicBase + '/api/auth/websocket-ticket') => request('/api/auth/websocket-ticket', {
    method: 'POST', headers: { authorization: 'DPoP ' + credential.access_token,
      dpop: await proof(url, credential.access_token), 'content-type': 'application/json' }, body: '{}' });
  const wrongProof = await mintTicket('http://tunnel.example.test/api/auth/websocket-ticket');
  assert.equal(wrongProof.status, 401);
  await wrongProof.arrayBuffer();
  const handshake = async (origin, expectedStatus, secret) => {
    if (!secret) {
      const result = await mintTicket(); assert.equal(result.status, 200);
      secret = (await result.json()).ticket;
    }
    const socket = new WebSocket(gateway.serverURL.replace('http:', 'ws:') + '/ws?orchestrationProtocol=1&wsTicket=' + secret,
      { origin, headers: forwarded });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { socket.terminate(); reject(new Error('Handshake timeout')); }, 5000);
      socket.on('error', () => {});
      socket.once('open', () => {
        clearTimeout(timeout); socket.close();
        try { assert.equal(expectedStatus, 101); resolve(); } catch (error) { reject(error); }
      });
      socket.once('unexpected-response', (_, response) => {
        clearTimeout(timeout); response.resume(); socket.terminate();
        try { assert.equal(response.statusCode, expectedStatus); resolve(); } catch (error) { reject(error); }
      });
    });
  };
  await handshake(publicBase, 101);
  await handshake('https://attacker.invalid', 403);
  await handshake(publicBase, 401, 'invalid-ticket');
  const logs = await readFile(join(directory, 'server-owned', 'connection-diagnostics.log'), 'utf8');
  assert.match(logs, /https-tunnel/);
  assert.match(logs, /origin-policy/);
  assert.match(logs, /url_mismatch/);
  for (const secret of [pairing.credential, credential.access_token, 'invalid-ticket', 'wsTicket=']) {
    assert.equal(logs.includes(secret), false);
  }
});
