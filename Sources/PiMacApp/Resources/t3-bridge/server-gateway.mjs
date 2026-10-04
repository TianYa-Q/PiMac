// Production entry: official T3 Server owns all public auth, RPC and Connect.
// Only the separately bound supervisor socket speaks Pi Mac administration IPC.
import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { acquireChildLease } from './child-lease.mjs';
import { isLoopbackPeer } from './network.mjs';
import { startPiServer, httpAllowed } from './vendor/t3-server.mjs';
import { createLANListener } from './lan-listener.mjs';
import { createPiAccountManagement } from './pi-account-management.mjs';

const json = (res, status, value) => {
  if (res.writableEnded) return;
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); res.end(JSON.stringify(value));
};
async function input(req) {
  if (req.headers['content-type']?.split(';')[0] !== 'application/json') throw new Error('Invalid input');
  const chunks = []; let size = 0;
  for await (const chunk of req) { size += chunk.length; if (size > 256 * 1024) throw new Error('Too large'); chunks.push(chunk); }
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
export async function createServerGateway({ token, directory, publicEndpoint, piConfig, onFailure, signal }) {
  if (!/^[a-f0-9]{64}$/.test(token ?? '')) throw new Error('Invalid supervisor token');
  const expected = Buffer.from('Bearer ' + token);
  let official, lan, closed = false;
  const piAccounts = createPiAccountManagement();
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
      if (route === 'GET /internal/auth/model-catalog') return json(res, 200, await manager.modelCatalog());
      if (route === 'GET /internal/auth/connect') return json(res, 200, await manager.status());
      if (route === 'GET /internal/auth/clients') return json(res, 200, await manager.clients());
      if (route === 'GET /internal/auth/lan') return json(res, 200, lan.status());
      if (route === 'GET /internal/auth/pairing-links') return json(res, 200, await manager.pairingLinks());
      if (!req.url.startsWith('/internal/auth/')) { json(res, 404, { error: 'use_t3_orchestration' }); req.resume(); return; }
      const body = await input(req); if (closed) throw new Error('Unavailable');
      if (route === 'POST /internal/auth/lan' && Object.keys(body).length === 1 && Object.hasOwn(body, 'endpoint') &&
          (body.endpoint === null || (typeof body.endpoint === 'object' && !Array.isArray(body.endpoint)))) {
        return json(res, 200, await lan.configure(body.endpoint));
      }
      if (route === 'POST /internal/auth/pairing' && Object.keys(body).length === 0) {
        if (!lan.status().endpoint) throw new Error('LAN not enabled');
        return json(res, 200, await manager.pairing({ label: 'Pi Mac LAN phone' }));
      }
      if (route === 'POST /internal/auth/account-status') return json(res, 200, { payload: JSON.stringify(await piAccounts.accountStatus(body)) });
      if (route === 'POST /internal/auth/model-preferences') return json(res, 200, await manager.modelPreferences(body));
      if (route === 'POST /internal/auth/connect' && Object.keys(body).length === 1) return json(res, 200, await manager.control(body.operation));
      if (route === 'POST /internal/auth/revoke-client' && typeof body.sessionId === 'string') return json(res, 200, await manager.revokeClient(body.sessionId));
      if (route === 'POST /internal/auth/revoke-pairing' && typeof body.id === 'string') return json(res, 200, await manager.revokePairing(body.id));
      json(res, 404, { error: 'not_found' });
    })().catch(error => json(res, 400, { error: error.code === 'EADDRINUSE' ? 'address_in_use' : 'control_failed' }));
  });
  server.requestTimeout = 15000; server.headersTimeout = 10000;
  const close = async () => {
    if (closed) return; closed = true; piAccounts.close(); server.close(); server.closeAllConnections(); await lan?.close(); await official?.close();
  };
  try {
    official = await startPiServer({ directory: path.join(directory, 'server-owned'), environmentId: identity(directory), piConfig, signal,
      onFailure: () => { void close(); onFailure?.(); } });
    lan = createLANListener({ localURL: official.localURL, allowed: httpAllowed });
    if (publicEndpoint) await lan.configure(publicEndpoint);
    return { server, serverURL: official.localURL, official, lan, close };
  } catch (error) { await close(); throw error; }
}

let entry;
try { entry = process.argv[1] && fs.realpathSync(process.argv[1]); } catch {}
if (entry === fileURLToPath(import.meta.url)) {
  process.umask(0o077);
  // A rapid relaunch after an app crash waits for the old child's finalizers;
  // it never steals a lock or opens the database while the old owner is alive.
  const release = acquireChildLease(process.env.PIMAC_T3_AUTH_FILE, { waitSeconds: 15 }); process.once('exit', release);
  const send = value => process.stdout.write(JSON.stringify(value) + '\n');
  let gateway, stopping = false;
  const startup = new AbortController();
  const parentPID = Number(process.env.PIMAC_T3_PARENT_PID ?? process.ppid);
  // EOF is primary; reparent detection is a fallback if a pipe writer was
  // accidentally inherited. No surviving Server after a crashed Mac owner.
  const parentWatch = setInterval(() => {
    if (process.ppid !== parentPID) void stop();
  }, 500);
  parentWatch.unref();
  const stop = async () => {
    if (stopping) return;
    stopping = true;
    clearInterval(parentWatch);
    startup.abort();
    process.stdin.destroy();
    await gateway?.close();
  };
  // Stdin carries lifetime only, never workspace data or Pi commands.
  process.stdin.resume(); process.stdin.on('end', () => void stop()); process.stdin.on('error', () => void stop());
  process.on('SIGTERM', () => void stop()); process.on('SIGINT', () => void stop());
  try {
    gateway = await createServerGateway({ token: process.env.PIMAC_T3_BRIDGE_TOKEN, directory: path.dirname(process.env.PIMAC_T3_AUTH_FILE),
      piConfig: { binaryPath: process.env.PIMAC_PI_BINARY || 'pi' }, signal: startup.signal, onFailure: () => { process.exitCode = 1; void stop(); } });
    if (stopping) await gateway.close();
    else {
      await new Promise((resolve, reject) => { gateway.server.once('error', reject); gateway.server.listen(0, '127.0.0.1', resolve); });
      send({ type: 'ready', port: gateway.server.address().port, serverPort: Number(new URL(gateway.serverURL).port) });
    }
  } catch { send({ type: 'startup_error', code: 'server_failed' }); await stop(); process.exitCode = 1; }
}
