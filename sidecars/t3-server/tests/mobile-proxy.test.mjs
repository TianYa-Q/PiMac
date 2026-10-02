import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import { createServerGateway, proxyServer } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';
import { call } from '../generated/client.mjs';
import WebSocket from 'ws';
import { originAllowed } from '../origin-policy.mjs';

test('Origin is allowed only for same-origin WebSocket upgrades', () => {
  const headers = { host: '192.168.0.110:3773', origin: 'http://192.168.0.110:3773', upgrade: 'websocket' };
  assert.equal(originAllowed('GET', '/ws?wsTicket=secret', headers), true);
  for (const origin of ['null', 'https://attacker.invalid', 'http://192.168.0.110:3774', 'http://user@192.168.0.110:3773', 'http://192.168.0.110:3773/path']) {
    assert.equal(originAllowed('GET', '/ws', { ...headers, origin }), false);
  }
  assert.equal(originAllowed('POST', '/api/auth/websocket-ticket', headers), false);
  assert.equal(originAllowed('GET', '/ws', { ...headers, upgrade: undefined }), false);
});

test('mobile DPoP exchange, ticket and WebSocket survive the public proxy', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-mobile-'));
  const gateway = await createServerGateway({ token: 'ab'.repeat(32), directory,
    piConfig: { binaryPath: process.execPath, binaryArgs: [new URL('./fixtures/pi.mjs', import.meta.url).pathname] } });
  const proxy = proxyServer(gateway.serverURL);
  t.after(async () => { proxy.close(); await gateway.close(); await rm(directory, { recursive: true, force: true }); });
  await new Promise(resolve => proxy.server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${proxy.server.address().port}`;
  assert.notEqual(base, gateway.serverURL);
  const tunnelDescriptor = await (await fetch(gateway.serverURL + '/.well-known/t3/environment')).json();
  const lanDescriptor = await (await fetch(base + '/.well-known/t3/environment')).json();
  assert.equal(tunnelDescriptor.label, 'Pi Mac · Tunnel');
  assert.equal(lanDescriptor.label, 'Pi Mac · LAN');
  assert.deepEqual(lanDescriptor, { ...tunnelDescriptor, label: 'Pi Mac · LAN' });
  const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
  const jwk = await exportJWK(publicKey);
  const proof = (url, accessToken) => new SignJWT({ htu: url, htm: 'POST', jti: randomUUID(),
    ...(accessToken ? { ath: createHash('sha256').update(accessToken).digest('base64url') } : {}) })
    .setProtectedHeader({ alg: 'ES256', typ: 'dpop+jwt', jwk }).setIssuedAt().sign(privateKey);
  const pairing = await gateway.official.management.pairing({ label: 'Phone fixture' });
  const tokenURL = base + '/oauth/token';
  const exchange = await fetch(tokenURL, { method: 'POST', headers: {
    'content-type': 'application/x-www-form-urlencoded', dpop: await proof(tokenURL),
  }, body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap',
    requested_token_type: 'urn:ietf:params:oauth:token-type:access_token', subject_token: pairing.credential }) });
  const credential = await exchange.json();
  assert.equal(exchange.status, 200, JSON.stringify(credential));
  assert.equal(credential.token_type, 'DPoP');
  const ticketURL = base + '/api/auth/websocket-ticket';
  const response = await fetch(ticketURL, { method: 'POST', headers: {
    authorization: 'DPoP ' + credential.access_token, dpop: await proof(ticketURL, credential.access_token),
    'content-type': 'application/json',
  }, body: '{}' });
  const ticket = await response.json();
  assert.equal(response.status, 200, JSON.stringify(ticket));
  const config = await call(base.replace('http:', 'ws:') + '/ws?orchestrationProtocol=1&wsTicket=' + ticket.ticket, 'server.getConfig');
  assert.equal(config.providers[0].driver, 'pi');
  // Match the iOS handshake: a same-origin Origin must survive both policies.
  const mintTicket = async () => {
    const result = await fetch(ticketURL, { method: 'POST', headers: {
      authorization: 'DPoP ' + credential.access_token,
      dpop: await proof(ticketURL, credential.access_token), 'content-type': 'application/json',
    }, body: '{}' });
    assert.equal(result.status, 200);
    return (await result.json()).ticket;
  };
  const handshake = async (origin, expectedStatus, secret) => {
    secret ??= await mintTicket();
    const socket = new WebSocket(base.replace('http:', 'ws:') + '/ws?orchestrationProtocol=1&wsTicket=' + secret, { origin });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { socket.terminate(); reject(new Error('Handshake timeout')); }, 5000);
      socket.on('error', () => {});
      socket.once('open', () => {
        clearTimeout(timeout);
        try { assert.equal(expectedStatus, 101); socket.close(); resolve(); } catch (error) { socket.terminate(); reject(error); }
      });
      socket.once('unexpected-response', (_, response) => {
        clearTimeout(timeout); response.resume(); socket.terminate();
        try { assert.equal(response.statusCode, expectedStatus); resolve(); } catch (error) { reject(error); }
      });
    });
  };
  await handshake(base, 101);
  await handshake('https://attacker.invalid', 404);
  await handshake(base, 401, 'invalid-ticket');
  // Cross-site browser origins remain denied; this fix does not relax auth.
  assert.equal((await fetch(base + '/.well-known/t3/environment', { headers: { origin: 'https://attacker.invalid' } })).status, 404);
});
