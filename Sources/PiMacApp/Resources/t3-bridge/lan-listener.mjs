// Optional LAN transport only. Official T3 owns pairing, DPoP, tickets and RPC.
// The Server and supervisor remain loopback-only; never forward host controls.
import http from 'node:http';
import { isPrivateAddress, isLoopbackPeer, validatePublicEndpoint } from './network.mjs';

// Hop-by-hop headers must not cross transports. WebSocket alone negotiates an
// upgrade; forwarding/control headers are never accepted from a LAN client.
export function proxyHeaders(headers, websocket = false) {
  const connection = String(headers.connection ?? '').toLowerCase().split(',').map(value => value.trim());
  const blocked = new Set(['connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
    'proxy-connection', 'te', 'trailer', 'transfer-encoding', 'upgrade', 'forwarded', 'x-pimac-control', ...connection]);
  const result = Object.fromEntries(Object.entries(headers).filter(([key]) =>
    !key.startsWith('x-forwarded-') && !blocked.has(key)));
  if (websocket) { result.connection = 'Upgrade'; result.upgrade = 'websocket'; }
  return result;
}

export function createLANListener({ localURL, allowed }) {
  let active = null, closed = false, pending = Promise.resolve(), closing;
  const status = () => ({ endpoint: active?.endpoint ?? null });
  const closeListener = listener => {
    if (!listener) return Promise.resolve();
    for (const socket of listener.sockets) socket.destroy();
    return new Promise(resolve => listener.server.close(resolve));
  };
  const open = async endpoint => {
    const sockets = new Set();
    const accept = req => {
      const peer = req.socket.remoteAddress?.replace(/^::ffff:/u, '');
      // Check the actual destination of each connection, not a stale interface
      // snapshot or arbitrary Host header. This survives Wi-Fi/IP changes.
      const local = req.socket.localAddress?.replace(/^::ffff:/u, '');
      const authority = `${local}:${endpoint.port}`;
      return !closed && (isPrivateAddress(peer) || isLoopbackPeer(peer)) &&
        req.headers.host === authority && req.url?.startsWith('/') && !req.url.startsWith('//') &&
        !['/api/connect/preferences', '/api/connect/unlink'].includes(req.url.split('?')[0]) &&
        allowed(req.method, req.url);
    };
    const server = http.createServer((req, res) => {
      if (!accept(req)) { res.writeHead(403); res.end(); req.resume(); return; }
      const upstream = http.request(localURL + req.url, { method: req.method, headers: proxyHeaders(req.headers) }, response => {
        res.writeHead(response.statusCode, proxyHeaders(response.headers)); response.pipe(res);
        response.on('error', () => res.destroy());
      });
      upstream.setTimeout(45_000, () => upstream.destroy());
      upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end(); });
      req.on('error', () => upstream.destroy());
      req.on('aborted', () => upstream.destroy());
      res.on('close', () => upstream.destroy());
      req.pipe(upstream);
    });
    server.on('upgrade', (req, socket, head) => {
      if (!accept(req) || req.url.split('?')[0] !== '/ws' || req.headers.upgrade?.toLowerCase() !== 'websocket') {
        socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n'); return;
      }
      const upstream = http.request(localURL + req.url, { method: 'GET', headers: proxyHeaders(req.headers, true) });
      const timeout = setTimeout(() => { upstream.destroy(); socket.destroy(); }, 10_000);
      const fail = () => { clearTimeout(timeout); socket.destroy(); upstream.destroy(); };
      upstream.on('error', fail);
      socket.on('error', fail);
      socket.on('close', () => { clearTimeout(timeout); upstream.destroy(); });
      upstream.on('response', response => {
        clearTimeout(timeout);
        socket.end(`HTTP/1.1 ${response.statusCode} Rejected\r\nConnection: close\r\n\r\n`);
        response.resume();
      });
      upstream.on('upgrade', (response, remote, upstreamHead) => {
        clearTimeout(timeout);
        sockets.add(remote); remote.once('close', () => sockets.delete(remote));
        const responseHeaders = Object.entries(proxyHeaders(response.headers, true)).flatMap(([key, value]) =>
          (Array.isArray(value) ? value : [value]).map(item => `${key}: ${item}\r\n`)).join('');
        socket.write(`HTTP/1.1 101 Switching Protocols\r\n${responseHeaders}\r\n`);
        if (head.length) remote.write(head);
        if (upstreamHead.length) socket.write(upstreamHead);
        socket.pipe(remote); remote.pipe(socket);
        remote.on('error', () => socket.destroy());
        remote.on('close', () => socket.destroy());
        socket.on('close', () => remote.destroy());
      });
      upstream.end();
    });
    server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
    server.requestTimeout = 45_000; server.headersTimeout = 10_000;
    await new Promise((resolve, reject) => {
      const failed = error => { server.removeListener('listening', ready); reject(error); };
      const ready = () => { server.removeListener('error', failed); resolve(); };
      server.once('error', failed);
      server.once('listening', ready);
      server.listen(endpoint.port, endpoint.host);
    });
    server.on('error', () => { for (const socket of sockets) socket.destroy(); });
    return { server, sockets, endpoint: { host: endpoint.host, port: endpoint.port } };
  };
  const configure = endpoint => {
    const operation = pending.then(async () => {
      if (closed) throw new Error('LAN listener closed');
      if (endpoint) {
        validatePublicEndpoint(endpoint);
        // Legacy IP+port callers are migrated to the same port-only listener.
        endpoint = { host: '0.0.0.0', port: endpoint.port };
      }
      if (endpoint && active?.endpoint.port === endpoint.port) return status();
      // Bind first: a failed new endpoint must not destroy an existing listener.
      const next = endpoint ? await open(endpoint) : null, previous = active;
      active = next;
      await closeListener(previous);
      return status();
    });
    pending = operation.catch(() => {});
    return operation;
  };
  return { status, configure, close() {
    if (!closing) {
      closed = true;
      closing = pending.then(async () => {
        const previous = active; active = null;
        await closeListener(previous);
      });
    }
    return closing;
  } };
}
