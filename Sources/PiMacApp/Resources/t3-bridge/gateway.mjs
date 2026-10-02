// Pi Mac IPC gateway with a narrow authenticated T3 RPC transport preview.
import http from 'node:http';
import { randomUUID, timingSafeEqual } from 'node:crypto';
import { createJSONLineReceiver } from './json-lines.mjs';
import { fileURLToPath } from 'node:url';
import { realpathSync } from 'node:fs';
import { AuthStore } from './auth-store.mjs';
import { handleT3Auth, handleLocalAuth, authError } from './auth-http.mjs';
import { attachT3RPC, WorkspaceProjection } from './vendor/rpc-runtime.mjs';
import { createWorkspaceIPC } from './workspace-ipc.mjs';
import { handleOrchestrationRead } from './orchestration-http.mjs';
import path from 'node:path';
import { validatePublicEndpoint, isLoopbackPeer } from './network.mjs';
import { acquireChildLease } from './child-lease.mjs';
import { createReadDiagnostics } from './diagnostics.mjs';

const MAX_BODY = 300 * 1024;
export function createGateway({ token, send, timeoutMs = 30_000, authStore, publicEndpoint }) {
  if (publicEndpoint) {
    validatePublicEndpoint(publicEndpoint);
    if (!authStore) throw new Error('Remote access requires an authorization store');
  }
  if (typeof token !== 'string' || !/^[a-f0-9]{64}$/.test(token)) {
    throw new Error('A 256-bit hexadecimal bridge token is required');
  }
  const expected = Buffer.from(`Bearer ${token}`);
  const pending = new Map();
  const reads = createWorkspaceIPC(send);
  const diagnostics = createReadDiagnostics();
  const workspace = authStore ? new WorkspaceProjection({
    environmentId: authStore.state.environmentId, request: async (method, fields) => {
      if (method === 'workspace.catalog') diagnostics.catalogStarted();
      try { return await reads.request(method, fields); }
      catch (error) { if (method === 'workspace.catalog') diagnostics.catalogFailed(); throw error; }
    },
    clockFile: authStore.file ? path.join(path.dirname(authStore.file), 'projection-clock.json') : undefined,
  }) : undefined;
  function respond(res, status, body) {
    res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' });
    res.end(JSON.stringify(body));
  }
  const handle = async (req, res, publicOnly = false) => {
    if (req.method === 'GET' && req.url.split('?')[0] === '/api/orchestration/shell') {
      diagnostics.httpStarted();
      res.once('finish', () => diagnostics.httpFinished(res.statusCode));
    }
    // The phone listener has NO administration or diagnostic endpoints, even
    // with the supervisor token. Admin remains on a separate loopback socket.
    if (req.url.startsWith('/internal/') && (publicOnly || !isLoopbackPeer(req.socket.remoteAddress))) {
      respond(res, 404, { error: 'not_found' }); req.resume(); return;
    }
    // Preview policy: browser/Origin-bearing HTTP is unsupported. Actual native
    // Origin behavior still needs validation against the App Store build.
    if (req.headers.origin !== undefined) {
      respond(res, 403, { error: 'browser_origin_not_allowed' });
      req.resume();
      return;
    }
    if (authStore && !req.url.startsWith('/internal/')) {
      try {
        if (await handleT3Auth(req, res, authStore)) return;
        if (await handleOrchestrationRead(req, res, authStore, workspace)) return;
        respond(res, 404, { error: 'not_found' });
      } catch (error) { authError(res, error); }
      req.resume();
      return;
    }
    const supplied = Buffer.from(req.headers.authorization ?? '');
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) {
      respond(res, 401, { error: 'unauthorized' });
      req.resume();
      return;
    }
    if (authStore && req.method === 'GET' && req.url === '/internal/auth/read-diagnostics') {
      respond(res, 200, diagnostics.snapshot());
      return;
    }
    if (authStore && req.url.startsWith('/internal/auth/')) {
      try {
        if (await handleLocalAuth(req, res, authStore)) return;
        respond(res, 404, { error: 'not_found' });
      } catch (error) { authError(res, error); }
      req.resume();
      return;
    }
    // No CORS, cookies or GET side effects on the private workspace bridge.
    if (req.method !== 'POST' || req.url !== '/internal/request') {
      respond(res, 404, { error: 'not_found' });
      req.resume();
      return;
    }
    if (pending.size >= 64) {
      respond(res, 503, { error: 'overloaded' });
      req.resume();
      return;
    }
    try {
      let size = 0;
      const chunks = [];
      for await (const chunk of req) {
        size += chunk.length;
        if (size > MAX_BODY) {
          respond(res, 413, { error: 'request_too_large' });
          return;
        }
        chunks.push(chunk);
      }
      const input = JSON.parse(Buffer.concat(chunks).toString('utf8'));
      if (!input || typeof input !== 'object' || Array.isArray(input) ||
          !['workspace.snapshot', 'session.prompt', 'session.abort'].includes(input.method) ||
          (input.target !== undefined && typeof input.target !== 'string') ||
          (input.text !== undefined && typeof input.text !== 'string')) {
        respond(res, 400, { error: 'invalid_request' });
        return;
      }
      if (pending.size >= 64) {
        respond(res, 503, { error: 'overloaded' });
        return;
      }
      const id = randomUUID();
      const timer = setTimeout(() => {
        pending.delete(id);
        // A timeout is an unknown outcome, never permission to automatically retry a mutation.
        respond(res, 504, { error: 'outcome_unknown', id });
      }, timeoutMs);
      pending.set(id, { res, timer });
      res.on('close', () => {
        clearTimeout(timer);
        pending.delete(id);
      });
      try {
        send({ id, method: input.method, target: input.target, text: input.text });
      } catch {
        clearTimeout(timer);
        pending.delete(id);
        respond(res, 503, { error: 'bridge_unavailable' });
      }
    } catch {
      if (!res.writableEnded) respond(res, 400, { error: 'invalid_request' });
    }
  };
  const server = http.createServer(handle);
  const publicServer = publicEndpoint ? http.createServer((req, res) => void handle(req, res, true)) : undefined;
  const publicRPC = publicServer ? attachT3RPC(publicServer, authStore, { workspace, diagnostics }) : undefined;
  const rpc = authStore ? attachT3RPC(server, authStore, { workspace, diagnostics }) : undefined;
  if (!rpc) server.on('upgrade', (_req, socket) => {
    socket.end('HTTP/1.1 503 Service Unavailable\r\nConnection: close\r\nContent-Length: 0\r\n\r\n');
  });
  for (const listener of [server, publicServer].filter(Boolean)) {
    listener.requestTimeout = 15_000;
    listener.headersTimeout = 10_000;
  }
  return {
    server, publicServer,
    receive(message) {
      reads.receive(message);
      const request = pending.get(message.id);
      if (!request) return;
      clearTimeout(request.timer);
      pending.delete(message.id);
      respond(request.res, 200, message);
    },
    close() {
      if (authStore) authStore.failed = true; // No delayed HTTP body may commit after shutdown.
      for (const { res, timer } of pending.values()) {
        clearTimeout(timer);
        respond(res, 503, { error: 'bridge_unavailable' });
      }
      pending.clear();
      rpc?.close();
      publicRPC?.close();
      publicServer?.close();
      publicServer?.closeAllConnections();
      workspace?.close();
      reads.close();
      server.close();
      server.closeAllConnections();
    },
  };
}

// Node resolves a module's URL through symlinks, but leaves argv[1] untouched
// (notably macOS /var -> /private/var and symlinked app installations).
let entryPath;
try { if (process.argv[1]) entryPath = realpathSync(process.argv[1]); } catch { /* Imported module. */ }
if (fileURLToPath(import.meta.url) === entryPath) {
  const release = acquireChildLease(process.env.PIMAC_T3_AUTH_FILE);
  process.once('exit', release);
  const gateway = createGateway({
    token: process.env.PIMAC_T3_BRIDGE_TOKEN,
    publicEndpoint: process.env.PIMAC_T3_PUBLIC_HOST ? {
      host: process.env.PIMAC_T3_PUBLIC_HOST, port: Number(process.env.PIMAC_T3_PUBLIC_PORT),
    } : undefined,
    authStore: new AuthStore({ file: process.env.PIMAC_T3_AUTH_FILE }),
    send: message => process.stdout.write(`${JSON.stringify(message)}\n`),
  });
  process.stdin.on('data', createJSONLineReceiver(message => gateway.receive(message), {
    onInvalid: () => process.stderr.write('Invalid bridge response\n'),
  }));
  const stop = () => { gateway.close(); process.stdin.destroy(); };
  process.stdin.on('end', () => gateway.close());
  process.stdin.on('error', stop);
  process.on('SIGTERM', stop);
  process.on('SIGINT', stop);
  const failed = error => {
    process.stdout.write(`${JSON.stringify({ type: 'startup_error', code: error.code === 'EADDRINUSE' ? 'address_in_use' : 'listen_failed' })}\n`);
    stop(); process.exitCode = 1;
  };
  gateway.server.on('error', failed);
  gateway.publicServer?.on('error', failed);
  // Always start local administration first. Publish ready only after every
  // requested listener succeeds; a failed bind never silently falls back.
  gateway.server.listen(0, '127.0.0.1', () => {
    const ready = () => process.stdout.write(`${JSON.stringify({ type: 'ready', port: gateway.server.address().port,
      ...(gateway.publicServer ? { publicHost: gateway.publicServer.address().address, publicPort: gateway.publicServer.address().port } : {}) })}\n`);
    if (gateway.publicServer) gateway.publicServer.listen(Number(process.env.PIMAC_T3_PUBLIC_PORT), process.env.PIMAC_T3_PUBLIC_HOST, ready);
    else ready();
  });
}
