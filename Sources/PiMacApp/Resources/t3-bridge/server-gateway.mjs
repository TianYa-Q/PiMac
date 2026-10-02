// Production entry: official T3 Server owns all public auth, RPC and Connect.
// Only the separately bound supervisor socket speaks Pi Mac administration IPC.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { acquireChildLease } from './child-lease.mjs';
import { isLoopbackPeer, validatePublicEndpoint } from './network.mjs';
import { startPiServer, httpAllowed, originAllowed } from './vendor/t3-server.mjs';

const json = (res, status, value) => {
  if (res.writableEnded) return;
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(value));
};
async function input(req) {
  if (req.headers['content-type']?.split(';')[0] !== 'application/json') throw new Error('Invalid input');
  const chunks = []; let size = 0;
  for await (const chunk of req) { size += chunk.length; if (size > 2048) throw new Error('Too large'); chunks.push(chunk); }
  const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
  if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error('Invalid input'); return body;
}
function identity(directory) {
  // Do not import a publish-only grant or its environment signing key into a
  // managed public endpoint. The official backend has a separate identity.
  fs.mkdirSync(directory, { mode: 0o700, recursive: true });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077)) throw new Error('Unsafe state directory');
  const file = path.join(directory, 'official-environment-id');
  if (!fs.existsSync(file)) {
    const fd = fs.openSync(file, fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_WRONLY | fs.constants.O_NOFOLLOW, 0o600);
    try { fs.writeFileSync(fd, randomUUID()); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
  }
  const state = fs.lstatSync(file);
  if (!state.isFile() || state.uid !== process.getuid() || (state.mode & 0o077) || state.size > 100) throw new Error('Unsafe environment identity');
  const id = fs.readFileSync(file, 'utf8'); if (!/^[0-9a-f-]{36}$/.test(id)) throw new Error('Invalid environment identity'); return id;
}
export function proxyServer(localURL, diagnose = () => {}) {
  const origin = new URL(localURL);
  const allowed = req => originAllowed(req.method, req.url, req.headers) && httpAllowed(req.method, req.url) && !req.url.startsWith('/internal/');
  const options = req => {
    // DPoP binds a proof to the URL the phone actually requested. Rewriting
    // Host to the loopback backend invalidates token exchange/ticket proofs.
    const headers = { ...req.headers };
    for (const name of ['x-pimac-control', 'forwarded', 'x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto']) delete headers[name];
    return { hostname: origin.hostname, port: origin.port, method: req.method, path: req.url, headers };
  };
  const server = http.createServer((req, res) => {
    if (!allowed(req)) { diagnose('HTTP 请求被访问策略拒绝（404）'); json(res, 404, { error: 'not_found' }); req.resume(); return; }
    const upstream = http.request(options(req), response => {
      if (req.url.split('?')[0] === '/api/auth/websocket-ticket') diagnose(`WebSocket ticket：HTTP ${response.statusCode}`);
      if (req.url.split('?')[0] === '/oauth/token') diagnose(`设备授权交换：HTTP ${response.statusCode}`);
      // LAN and managed Tunnel share identity/auth, but must be distinguishable
      // in the phone's environment picker. Only rewrite the public descriptor.
      if (req.method === 'GET' && req.url.split('?')[0] === '/.well-known/t3/environment' && response.statusCode === 200) {
        const chunks = [];
        response.on('data', chunk => chunks.push(chunk));
        response.on('end', () => {
          try {
            const descriptor = JSON.parse(Buffer.concat(chunks).toString('utf8'));
            json(res, 200, { ...descriptor, label: 'Pi Mac · LAN' });
          } catch { json(res, 502, { error: 'server_unavailable' }); }
        });
        response.on('error', () => json(res, 502, { error: 'server_unavailable' }));
        return;
      }
      res.writeHead(response.statusCode, response.headers); response.pipe(res);
    });
    upstream.on('error', () => json(res, 502, { error: 'server_unavailable' }));
    req.on('aborted', () => upstream.destroy()); res.on('close', () => upstream.destroy()); req.pipe(upstream);
  });
  const sockets = new Set();
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  server.on('upgrade', (req, socket, head) => {
    if (!allowed(req) || req.url.split('?')[0] !== '/ws') {
      // Never include query strings: WebSocket tickets are credentials.
      const pathname = req.url.split('?')[0].replace(/[^a-zA-Z0-9/_.-]/g, '_').slice(0, 120);
      diagnose(`WebSocket 代理拒绝（404）：method=${req.method}，path=${pathname}，Origin=${req.headers.origin === undefined ? '无' : '有'}；原因=${req.headers.origin !== undefined ? 'Origin 策略' : pathname !== '/ws' ? '路径不是 /ws' : 'HTTP 方法策略'}`);
      socket.end('HTTP/1.1 404 Not Found\r\nConnection: close\r\nContent-Length: 0\r\n\r\n'); return;
    }
    const upstream = http.request(options(req));
    upstream.on('upgrade', (response, target, serverHead) => {
      diagnose('WebSocket 握手成功（101）');
      socket.write(`HTTP/1.1 101 Switching Protocols\r\n${Object.entries(response.headers).map(([key, value]) => `${key}: ${value}`).join('\r\n')}\r\n\r\n`);
      if (serverHead.length) socket.write(serverHead); if (head.length) target.write(head);
      socket.pipe(target).pipe(socket); socket.on('error', () => target.destroy()); target.on('error', () => socket.destroy());
      socket.once('close', () => target.destroy()); target.once('close', () => socket.destroy());
    });
    upstream.on('response', response => { diagnose(`WebSocket 握手被 Server 拒绝：HTTP ${response.statusCode}`); response.resume(); socket.end(`HTTP/1.1 ${response.statusCode} Unauthorized\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`); });
    upstream.on('error', () => socket.destroy()); socket.once('close', () => upstream.destroy()); upstream.end();
  });
  server.requestTimeout = 15000; server.headersTimeout = 10000;
  return { server, close() { server.close(); for (const socket of sockets) socket.destroy(); } };
}


export async function createServerGateway({ token, directory, publicEndpoint, piConfig, onFailure }) {
  if (!/^[a-f0-9]{64}$/.test(token ?? '')) throw new Error('Invalid supervisor token');
  const expected = Buffer.from('Bearer ' + token);
  let official, proxy, closed = false, networkBusy = false;
  const network = async endpoint => {
    if (closed || networkBusy) throw new Error('Network operation unavailable');
    networkBusy = true;
    try {
      proxy?.close(); proxy = undefined;
      if (endpoint) {
        validatePublicEndpoint(endpoint);
        official.broker.networkDiagnostic = '尚未收到局域网配对/连接请求';
        const next = proxyServer(official.localURL, message => {
          official.broker.networkDiagnostic = `${new Date().toISOString()} · ${message}`;
        });
        try { await new Promise((resolve, reject) => { next.server.once('error', reject); next.server.listen(endpoint.port, endpoint.host, resolve); }); }
        catch (error) { next.close(); throw error; }
        proxy = next;
      }
      return { publicURL: proxy ? 'http://' + endpoint.host + ':' + endpoint.port : null };
    } finally { networkBusy = false; }
  };
  const server = http.createServer((req, res) => {
    const supplied = Buffer.from(req.headers.authorization ?? '');
    if (!isLoopbackPeer(req.socket.remoteAddress) || req.headers.origin !== undefined ||
        supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) {
      json(res, 401, { error: 'unauthorized' }); req.resume(); return;
    }
    void (async () => {
      if (closed || !official) throw new Error('Unavailable');
      const manager = official.management, route = req.method + ' ' + req.url;
      if (route === 'POST /internal/auth/desktop-session') return json(res, 200, await manager.desktopSession());
      if (route === 'GET /internal/auth/connect') return json(res, 200, await manager.status());
      if (route === 'GET /internal/auth/clients') return json(res, 200, await manager.clients());
      if (route === 'GET /internal/auth/pairing-links') return json(res, 200, await manager.pairingLinks());
      if (!req.url.startsWith('/internal/auth/')) { json(res, 404, { error: 'use_t3_orchestration' }); req.resume(); return; }
      const body = await input(req); if (closed) throw new Error('Unavailable');
      if (route === 'POST /internal/auth/session-metrics' && typeof body.threadId === 'string') return json(res, 200, await manager.sessionMetrics(body.threadId));
      if (route === 'POST /internal/auth/account-status' && typeof body.threadId === 'string') return json(res, 200, await manager.accountStatus(body.threadId, typeof body.provider === 'string' ? body.provider : undefined));
      if (route === 'POST /internal/auth/network') return json(res, 200, await network(body.host ? { host: body.host, port: Number(body.port) } : undefined));
      if (route === 'POST /internal/auth/connect' && Object.keys(body).length === 1) return json(res, 200, await manager.control(body.operation));
      if (route === 'POST /internal/auth/pairing' && typeof body.label === 'string' && body.label.length <= 100) return json(res, 200, await manager.pairing(body));
      if (route === 'POST /internal/auth/revoke-client' && typeof body.sessionId === 'string') return json(res, 200, await manager.revokeClient(body.sessionId));
      if (route === 'POST /internal/auth/revoke-pairing' && typeof body.id === 'string') return json(res, 200, await manager.revokePairing(body.id));
      json(res, 404, { error: 'not_found' });
    })().catch(error => json(res, 400, { error: error.code === 'EADDRINUSE' ? 'address_in_use' : 'control_failed' }));
  });
  server.requestTimeout = 15000; server.headersTimeout = 10000;
  const close = async () => {
    if (closed) return; closed = true; proxy?.close(); server.close(); server.closeAllConnections(); await official?.close();
  };
  try {
    official = await startPiServer({ directory: path.join(directory, 'server-owned'), environmentId: identity(directory), piConfig,
      onFailure: () => { void close(); onFailure?.(); } });
    if (publicEndpoint) await network(publicEndpoint);
    return { server, get publicServer() { return proxy?.server; }, serverURL: official.localURL, official, close };
  } catch (error) { await close(); throw error; }
}

let entry;
try { entry = process.argv[1] && fs.realpathSync(process.argv[1]); } catch {}
if (entry === fileURLToPath(import.meta.url)) {
  process.umask(0o077);
  const release = acquireChildLease(process.env.PIMAC_T3_AUTH_FILE); process.once('exit', release);
  const send = value => process.stdout.write(JSON.stringify(value) + '\n');
  let gateway, stopping = false;
  const stop = async () => { if (stopping) return; stopping = true; process.stdin.destroy(); await gateway?.close(); };
  // Stdin carries lifetime only, never workspace data or Pi commands.
  process.stdin.resume(); process.stdin.on('end', () => void stop()); process.stdin.on('error', () => void stop());
  process.on('SIGTERM', () => void stop()); process.on('SIGINT', () => void stop());
  try {
    gateway = await createServerGateway({ token: process.env.PIMAC_T3_BRIDGE_TOKEN, directory: path.dirname(process.env.PIMAC_T3_AUTH_FILE),
      piConfig: { binaryPath: process.env.PIMAC_PI_BINARY || 'pi' }, onFailure: () => { process.exitCode = 1; void stop(); } });
    if (stopping) await gateway.close();
    else {
      await new Promise((resolve, reject) => { gateway.server.once('error', reject); gateway.server.listen(0, '127.0.0.1', resolve); });
      send({ type: 'ready', port: gateway.server.address().port, serverPort: Number(new URL(gateway.serverURL).port) });
    }
  } catch { send({ type: 'startup_error', code: 'server_failed' }); await stop(); process.exitCode = 1; }
}
