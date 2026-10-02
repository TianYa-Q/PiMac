// Narrow T3 transport adapter. Schema baseline: pingdotgg/t3code
// a97a4a9d189f145afe79c3a6f8533bbf9a6b40b1, contracts/src/rpc.ts.
// Snapshots and native shared-session sends; no orchestration engine is imported.
import * as Effect from 'effect/Effect';
import * as Logger from 'effect/Logger';
import * as Cause from 'effect/Cause';
import * as Queue from 'effect/Queue';
import * as Stream from 'effect/Stream';
import * as Socket from 'effect/unstable/socket/Socket';
import * as SocketServer from 'effect/unstable/socket/SocketServer';
import * as RpcServer from 'effect/unstable/rpc/RpcServer';
import * as RpcSerialization from 'effect/unstable/rpc/RpcSerialization';
import { WebSocketServer } from 'ws';
import { readGroup as group, ShellSnapshot, ThreadSnapshot } from './read-schemas.mjs';
import * as Schema from 'effect/Schema';
import { previewServerConfig } from './config.mjs';
import { CommandDispatcher } from './commands.mjs';
export { previewServerConfig } from './config.mjs';
export { WorkspaceProjection } from './workspace.mjs';
export function validateReadSnapshot(value, kind) {
  return Schema.encodeSync(kind === 'shell' ? ShellSnapshot : ThreadSnapshot)(value);
}

// One scoped Effect RPC server per authenticated socket. Closing the socket
// interrupts its handlers and protocol fibers, including outstanding requests.
function serve(ws, session, store, workspace, dispatcher, signal, diagnostics) {
  let streams = 0;
  const config = () => store.isLive(session.sessionId)?.scopes.includes('orchestration:read')
    ? Effect.sync(() => previewServerConfig(store.state.environmentId))
    : Effect.fail({ _tag: 'EnvironmentAuthorizationError', message: 'Scope required', requiredScope: 'orchestration:read' });
  const staticStream = read => Stream.fromEffect(read).pipe(Stream.concat(Stream.never));
  const subscribe = (kind, input) => Stream.callback(queue => Effect.gen(function* () {
    const live = store.isLive(session.sessionId);
    if (!live?.scopes.includes('orchestration:read')) {
      Queue.failCauseUnsafe(queue, Cause.fail({ _tag: 'EnvironmentAuthorizationError', message: 'Scope required', requiredScope: 'orchestration:read' }));
      return;
    }
    if (!workspace || streams >= 4) {
      Queue.failCauseUnsafe(queue, Cause.fail({ _tag: 'OrchestrationGetSnapshotError', message: 'Read subscription unavailable' }));
      return;
    }
    streams++;
    if (kind === 'shell') diagnostics?.event('shell_subscription');
    const stop = workspace.watch(kind, input,
      batch => {
        if (kind === 'shell') for (const item of batch) diagnostics?.event(`shell_${item.kind}`);
        Queue.offerUnsafe(queue, batch);
      },
      error => {
        if (kind === 'shell') diagnostics?.event('shell_stream_failed');
        Queue.failCauseUnsafe(queue, Cause.fail(error));
      });
    yield* Effect.addFinalizer(() => Effect.sync(() => { streams--; stop(); }));
  }), { capacity: 1, strategy: 'sliding' }).pipe(Stream.flatMap(batch => Stream.fromIterable(batch)));
  const program = Effect.gen(function* () {
    const socket = yield* Socket.fromWebSocket(Effect.succeed(ws), { highWaterMark: 12 * 1024 * 1024 });
    const protocol = yield* RpcServer.makeProtocolSocketServer.pipe(
      Effect.provideService(SocketServer.SocketServer, {
        address: { _tag: 'InetAddress', hostname: '127.0.0.1', port: 0 },
        run: handler => handler(socket).pipe(Effect.andThen(Effect.never)),
      }),
    );
    yield* RpcServer.make(group, { disableTracing: true, concurrency: 8 }).pipe(
      Effect.provideService(RpcServer.Protocol, protocol),
      Effect.provide(group.toLayer({
        'server.probe': () => store.isLive(session.sessionId)
          ? Effect.succeed({})
          : Effect.fail({ _tag: 'EnvironmentAuthorizationError', message: 'Session unavailable', requiredScope: 'orchestration:read' }),
        'server.getConfig': config,
        'server.getSettings': () => config().pipe(Effect.map(value => value.settings)),
        'subscribeServerConfig': input => staticStream(config().pipe(Effect.map(value => [
          { version: 1, type: 'snapshot', config: value },
          ...(input.environmentThemes ? [{ version: 1, type: 'environmentThemesUpdated', payload: { themes: [] } }] : []),
          ...(input.usageLimitSources ? [{ version: 1, type: 'usageLimitSourcesUpdated', payload: { sources: [] } }] : []),
        ]))).pipe(Stream.flatMap(Stream.fromIterable)),
        'subscribeServerLifecycle': () => staticStream(config().pipe(Effect.map(value => [
          { version: 1, sequence: 0, type: 'welcome', payload: { environment: value.environment,
            cwd: value.cwd, projectName: 'Pi Mac', bootstrapStatus: 'complete' } },
          { version: 1, sequence: 1, type: 'ready', payload: { environment: value.environment, at: new Date().toISOString() } },
        ]))).pipe(Stream.flatMap(Stream.fromIterable)),
        'orchestration.dispatchCommand': input => {
          const live = store.isLive(session.sessionId);
          if (!live?.scopes.includes('orchestration:operate')) {
            return Effect.fail({ _tag: 'EnvironmentAuthorizationError', message: 'Scope required', requiredScope: 'orchestration:operate' });
          }
          return Effect.tryPromise({ try: signal => dispatcher.dispatch(input, session.sessionId, signal), catch: error => error });
        },
        'orchestration.subscribeShell': input => subscribe('shell', input),
        'orchestration.subscribeThread': input => subscribe('thread', input),
      })),
    );
  }).pipe(Effect.scoped, Effect.provide(RpcSerialization.layerJson), Effect.provide(Logger.layer([])));
  return Effect.runPromise(program, { signal });
}

export function attachT3RPC(server, store, { workspace, diagnostics, maxConnections = 16, checkIntervalMs = 1000 } = {}) {
  const wss = new WebSocketServer({ noServer: true, maxPayload: 12 * 1024 * 1024,
    perMessageDeflate: false, clientTracking: true });
  const active = new Map();
  const dispatcher = new CommandDispatcher(workspace);
  let closed = false;
  const reject = (socket, status) => {
    socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`);
  };
  const check = () => {
    for (const [ws, { session, controller }] of active) {
      if (!store.isLive(session.sessionId)) {
        ws.close(1008, 'Session unavailable');
        controller.abort();
      }
    }
  };
  const unsubscribe = store.subscribe(check);
  const timer = setInterval(check, checkIntervalMs);
  timer.unref();
  const upgrade = (req, socket, head) => {
    // Validate routing/handshake BEFORE consuming the single-use credential.
    if (closed) return reject(socket, '503 Service Unavailable');
    // SocketRocket/native iOS may supply an Origin. Accept only this exact
    // listening endpoint, never a Host-header-derived or arbitrary web origin.
    let originAllowed = req.headers.origin === undefined;
    if (!originAllowed) {
      try {
        const origin = new URL(req.headers.origin);
        const address = server.address();
        originAllowed = origin.origin === `http://${address.address}:${address.port}` &&
          origin.pathname === '/' && !origin.search && !origin.hash && !origin.username && !origin.password;
      } catch { /* Invalid Origin is denied before ticket consumption. */ }
    }
    if (!originAllowed || req.headers.dpop !== undefined ||
        req.headers.authorization !== undefined || req.headers.cookie !== undefined) {
      return reject(socket, '403 Forbidden');
    }
    let url;
    try { url = new URL(req.url, 'http://127.0.0.1'); }
    catch { return reject(socket, '400 Bad Request'); }
    if (req.method !== 'GET' || url.pathname !== '/ws') return reject(socket, '404 Not Found');
    if (url.searchParams.getAll('orchestrationProtocol').length !== 1 ||
        url.searchParams.get('orchestrationProtocol') !== '1') return reject(socket, '409 Conflict');
    if (req.headers.upgrade?.toLowerCase() !== 'websocket' ||
        req.headers['sec-websocket-version'] !== '13' ||
        !/^[+/0-9A-Za-z]{22}==$/.test(req.headers['sec-websocket-key'] ?? '') ||
        req.headers['sec-websocket-protocol'] !== undefined) return reject(socket, '400 Bad Request');
    if (active.size >= maxConnections || [...store.connections.values()].reduce((sum, value) => sum + value.count, 0) >= maxConnections) {
      return reject(socket, '503 Service Unavailable');
    }
    if (url.searchParams.getAll('wsTicket').length !== 1) return reject(socket, '401 Unauthorized');
    let session;
    try { session = store.consumeTicket(url.searchParams.get('wsTicket')); }
    catch { return reject(socket, '401 Unauthorized'); }
    // No alternate Bearer/private-admin credential path. A ticket binds this
    // connection to exactly one device session; client-provided headers cannot
    // change the identity of individual RPC requests.
    try {
      wss.handleUpgrade(req, socket, head, ws => {
        const controller = new AbortController();
        active.set(ws, { session, controller });
        store.connected(session.sessionId);
        const expiry = setTimeout(check, Math.max(1, Math.min(2 ** 31 - 1, session.expiresAt - store.now())));
        expiry.unref();
        let termination;
        let finished = false;
        // ws itself waits up to 30 seconds for peer closure. Revocation/error
        // cleanup must not depend on the remote client replying to close frames.
        controller.signal.addEventListener('abort', () => {
          if (!finished) {
            termination = setTimeout(() => ws.terminate(), 1000);
            termination.unref();
          }
        }, { once: true });
        const outstanding = new Set();
        const send = ws.send.bind(ws);
        ws.send = (data, ...args) => {
          if (ws.bufferedAmount > 1024 * 1024) {
            ws.close(1008, 'Slow consumer'); controller.abort(); return;
          }
          const text = typeof data === 'string' ? data : Buffer.from(data).toString('utf8');
          if (text.includes('"_tag":"Exit"')) {
            try { const frame = JSON.parse(text); if (frame._tag === 'Exit') outstanding.delete(String(frame.requestId)); } catch { /* Protocol owns encoding. */ }
          }
          return send(data, ...args);
        };
        let frames = 0;
        let window = Date.now();
        ws.on('error', () => controller.abort());
        ws.once('close', () => {
          finished = true;
          clearTimeout(expiry);
          clearTimeout(termination);
          active.delete(ws);
          store.disconnected(session.sessionId);
          controller.abort();
        });
        ws.on('message', data => {
          check();
          if (ws.bufferedAmount > 1024 * 1024) {
            ws.close(1008, 'Slow consumer'); controller.abort(); return;
          }
          if (Date.now() - window >= 1000) { frames = 0; window = Date.now(); }
          let weight;
          try {
            // Effect sets ws.binaryType = 'arraybuffer'. ArrayBuffer.toString()
            // is not UTF-8 JSON; native clients may send binary JSON frames.
            const value = JSON.parse(typeof data === 'string' ? data : Buffer.from(data).toString('utf8'));
            const packets = Array.isArray(value) ? value : [value];
            weight = Math.max(1, packets.length);
            for (const packet of packets) if (packet?._tag === 'Request') {
              const id = String(packet.id);
              if (!['string', 'number'].includes(typeof packet.id) || !id.length || id.length > 128 || outstanding.has(id) || outstanding.size >= 16) {
                ws.close(1008, 'Request capacity exceeded'); controller.abort(); return;
              }
              outstanding.add(id);
              diagnostics?.rpc(packet.tag);
            }
          } catch {
            ws.close(1007, 'Invalid RPC JSON');
            controller.abort();
            return;
          }
          frames += weight;
          if (frames > 128) {
            ws.close(1008, 'Request rate exceeded');
            controller.abort();
          }
        });
        void serve(ws, session, store, workspace, dispatcher, controller.signal, diagnostics).catch(() => {
          if (ws.readyState === ws.OPEN) ws.close(1011, 'RPC unavailable');
          controller.abort();
        });
      });
    } catch { socket.destroy(); }
  };
  server.on('upgrade', upgrade);
  return {
    close() {
      if (closed) return;
      closed = true;
      clearInterval(timer);
      unsubscribe();
      server.off('upgrade', upgrade);
      // Terminate rather than wait indefinitely for a peer's close handshake.
      for (const ws of active.keys()) ws.terminate();
      wss.close();
    },
  };
}
