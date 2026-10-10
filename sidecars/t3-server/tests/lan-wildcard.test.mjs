import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import { createLANListener } from '../../../Sources/PiMacApp/Resources/t3-bridge/lan-listener.mjs';
import { isPrivateAddress, validatePublicEndpoint } from '../../../Sources/PiMacApp/Resources/t3-bridge/network.mjs';

test('wildcard validation works offline but rejects malformed ports and arbitrary hosts', () => {
  assert.deepEqual(validatePublicEndpoint({ host: '0.0.0.0', port: 3773 }, {}), { host: '0.0.0.0', port: 3773 });
  for (const port of [0, 1023, 65536, '3773', 3773.5]) {
    assert.throws(() => validatePublicEndpoint({ host: '0.0.0.0', port }, {}));
  }
  for (const host of ['::', 'example.com', '8.8.8.8', '192.168.99.250']) {
    assert.throws(() => validatePublicEndpoint({ host, port: 3773 }, {}));
  }
});

test('one wildcard listener serves current destinations and rejects spoofed Host headers', { timeout: 5000 }, async t => {
  const upstream = http.createServer((req, res) => res.end(req.headers.host));
  await new Promise(resolve => upstream.listen(0, '127.0.0.1', resolve));
  const lan = createLANListener({ localURL: `http://127.0.0.1:${upstream.address().port}`, allowed: () => true });
  t.after(async () => {
    await lan.close();
    upstream.closeAllConnections();
    await new Promise(resolve => upstream.close(resolve));
  });
  const reservation = net.createServer();
  await new Promise(resolve => reservation.listen(0, '0.0.0.0', resolve));
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const endpoint = { host: '0.0.0.0', port };
  assert.deepEqual(await lan.configure(endpoint), { endpoint });
  // Legacy IP configuration is also port-only and idempotent.
  assert.deepEqual(await lan.configure({ host: '127.0.0.1', port }), { endpoint });
  const addresses = ['127.0.0.1', ...new Set(Object.values(os.networkInterfaces()).flat()
    .filter(item => item && isPrivateAddress(item.address)).map(item => item.address))];
  const request = (address, host) => new Promise((resolve, reject) => {
    const req = http.get({ hostname: address, port, path: '/', headers: { host } }, res => {
      let body = '';
      res.on('data', chunk => { body += chunk; });
      res.on('end', () => resolve({ status: res.statusCode, body }));
    });
    req.on('error', reject);
  });
  for (const address of addresses) {
    const authority = `${address}:${port}`;
    assert.deepEqual(await request(address, authority), { status: 200, body: authority });
    for (const host of ['attacker.invalid', `0.0.0.0:${port}`, `${address}:${port + 1}`]) {
      assert.equal((await request(address, host)).status, 403);
    }
  }
  assert.deepEqual(lan.status(), { endpoint });
});
