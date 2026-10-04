import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import net from 'node:net';
import { createLANListener, proxyHeaders } from '../../../Sources/PiMacApp/Resources/t3-bridge/lan-listener.mjs';

async function listen(server) {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  return server.address().port;
}
async function freePort() {
  const server = net.createServer();
  const port = await listen(server);
  await new Promise(resolve => server.close(resolve));
  return port;
}

test('HTTP proxy strips hop-by-hop, nominated and forwarding headers without dropping auth', () => {
  const headers = { host: '192.168.1.2:3773', authorization: 'DPoP fixture', dpop: 'proof',
    connection: 'keep-alive, x-private', 'keep-alive': 'timeout=5', 'x-private': 'secret',
    'transfer-encoding': 'chunked', upgrade: 'websocket', forwarded: 'proto=https',
    'x-forwarded-proto': 'https', 'x-pimac-control': 'control', 'proxy-authorization': 'proxy' };
  assert.deepEqual(proxyHeaders(headers), { host: headers.host, authorization: headers.authorization, dpop: 'proof' });
  assert.deepEqual(proxyHeaders(headers, true), {
    host: headers.host, authorization: headers.authorization, dpop: 'proof', connection: 'Upgrade', upgrade: 'websocket',
  });
});

test('proxy streams chunked bodies and sanitizes response hop headers', { timeout: 5000 }, async t => {
  let observed;
  const upstream = http.createServer(async (req, res) => {
    observed = req.headers;
    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    res.writeHead(200, { connection: 'x-upstream', 'x-upstream': 'private', 'content-type': 'text/plain' });
    res.end(Buffer.concat(chunks));
  });
  const upstreamPort = await listen(upstream);
  const lan = createLANListener({ localURL: `http://127.0.0.1:${upstreamPort}`, allowed: () => true });
  t.after(async () => { await lan.close(); upstream.closeAllConnections(); await new Promise(resolve => upstream.close(resolve)); });
  const port = await freePort();
  await lan.configure({ host: '127.0.0.1', port });
  const result = await new Promise((resolve, reject) => {
    const req = http.request(`http://127.0.0.1:${port}/upload`, { method: 'POST', headers: {
      connection: 'x-private', 'x-private': 'secret', 'x-forwarded-for': 'spoof', authorization: 'DPoP fixture',
    } }, res => {
      const chunks = [];
      res.on('data', chunk => chunks.push(chunk));
      res.on('end', () => resolve({ body: Buffer.concat(chunks).toString(), headers: res.headers }));
      res.on('error', reject);
    });
    req.on('error', reject); req.write('one'); req.end('two');
  });
  assert.equal(result.body, 'onetwo');
  assert.equal(result.headers['x-upstream'], undefined);
  assert.equal(observed['x-private'], undefined);
  assert.equal(observed['x-forwarded-for'], undefined);
  assert.equal(observed.authorization, 'DPoP fixture');
});

test('concurrent shutdowns share a barrier and close stalled websocket handshakes', { timeout: 5000 }, async t => {
  const upstreamSockets = new Set();
  let started;
  const reachedUpstream = new Promise(resolve => { started = resolve; });
  const upstream = http.createServer();
  upstream.on('upgrade', (_req, socket) => { upstreamSockets.add(socket); started(); });
  const upstreamPort = await listen(upstream);
  const lan = createLANListener({ localURL: `http://127.0.0.1:${upstreamPort}`, allowed: () => true });
  t.after(async () => { await lan.close(); for (const socket of upstreamSockets) socket.destroy(); await new Promise(resolve => upstream.close(resolve)); });
  const port = await freePort();
  await lan.configure({ host: '127.0.0.1', port });
  const client = net.connect(port, '127.0.0.1');
  client.on('error', () => {});
  client.resume();
  const disconnected = new Promise(resolve => client.once('close', resolve));
  client.write(`GET /ws HTTP/1.1\r\nHost: 127.0.0.1:${port}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n`);
  await reachedUpstream;
  const first = lan.close();
  assert.equal(lan.close(), first);
  await first;
  await disconnected;
  assert.deepEqual(lan.status(), { endpoint: null });
  await assert.rejects(lan.configure({ host: '127.0.0.1', port }), /closed/);
});
