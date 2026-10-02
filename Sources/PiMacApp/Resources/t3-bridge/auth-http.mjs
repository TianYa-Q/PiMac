import { AuthFailure } from './auth-store.mjs';
import { environmentDescriptor, DEFAULT_SCOPES } from './protocol.mjs';

export function jsonResponse(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store', pragma: 'no-cache' });
  res.end(JSON.stringify(body));
}

async function body(req, form = false) {
  const expected = form ? 'application/x-www-form-urlencoded' : 'application/json';
  if (req.headers['content-type']?.split(';')[0].trim() !== expected) {
    throw new AuthFailure(400, 'invalid_request', 'invalid_command');
  }
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > 16 * 1024) throw new AuthFailure(413, 'invalid_request', 'invalid_command');
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  try {
    if (form) {
      const fields = new URLSearchParams(text);
      if ([...fields.keys()].some(key => fields.getAll(key).length > 1)) throw new Error('duplicate field');
      return Object.fromEntries(fields);
    }
    const parsed = JSON.parse(text);
    if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) throw new Error('object required');
    return parsed;
  } catch { throw new AuthFailure(400, 'invalid_request', 'invalid_command'); }
}

// Local admin endpoints use the private sidecar token, never a T3 device credential.
export async function handleLocalAuth(req, res, store) {
  const key = `${req.method} ${req.url}`;
  if (key === 'POST /internal/auth/pairing') {
    const input = await body(req);
    jsonResponse(res, 200, store.createPairing(input));
  } else if (key === 'GET /internal/auth/clients') {
    jsonResponse(res, 200, store.clients());
  } else if (key === 'POST /internal/auth/revoke-client') {
    const input = await body(req);
    if (typeof input.sessionId !== 'string') throw new AuthFailure(400, 'invalid_request', 'invalid_command');
    jsonResponse(res, 200, { revoked: store.revoke(input.sessionId) });
  } else if (key === 'GET /internal/auth/pairing-links') {
    jsonResponse(res, 200, store.pairingLinks());
  } else if (key === 'POST /internal/auth/revoke-pairing') {
    const input = await body(req);
    if (typeof input.id !== 'string') throw new AuthFailure(400, 'invalid_request', 'invalid_command');
    jsonResponse(res, 200, { revoked: store.revokePairing(input.id) });
  } else return false;
  return true;
}

export async function handleT3Auth(req, res, store) {
  const key = `${req.method} ${req.url}`;
  if (key === 'GET /.well-known/t3/environment') {
    jsonResponse(res, 200, environmentDescriptor(store.state.environmentId));
    return true;
  }
  if (key === 'GET /api/auth/session') {
    jsonResponse(res, 200, store.sessionState(req.headers.authorization));
    return true;
  }
  if (key === 'POST /oauth/token') {
    // Managed relay/DPoP is not implemented. Never silently downgrade a DPoP exchange.
    if (req.headers.dpop !== undefined) throw new AuthFailure(401, 'auth_invalid', 'invalid_credential');
    const input = await body(req, true);
    const metadata = { ipAddress: req.socket.remoteAddress,
      ...(req.headers['user-agent'] ? { userAgent: req.headers['user-agent'].slice(0, 512) } : {}) };
    jsonResponse(res, 200, store.exchange(input, metadata));
    return true;
  }
  const routes = new Set([
    'POST /api/auth/websocket-ticket', 'POST /api/auth/pairing-token',
    'GET /api/auth/pairing-links', 'POST /api/auth/pairing-links/revoke',
    'GET /api/auth/clients', 'POST /api/auth/clients/revoke',
    'POST /api/auth/clients/revoke-others',
  ]);
  if (!routes.has(key)) return false;
  const session = store.authenticate(req.headers.authorization);
  if (key === 'POST /api/auth/websocket-ticket') {
    jsonResponse(res, 200, store.createTicket(session));
    return true;
  }
  const write = req.method === 'POST';
  store.requireScope(session, write ? 'access:write' : 'access:read');
  if (key === 'POST /api/auth/pairing-token') {
    const input = await body(req);
    if (input.scopes !== undefined && (!Array.isArray(input.scopes) || input.scopes.some(s => !session.scopes.includes(s)))) {
      throw new AuthFailure(400, 'invalid_request', 'scope_not_granted');
    }
    // Defaults must also be a subset of the caller's authority.
    const selected = input.scopes ?? DEFAULT_SCOPES;
    if (selected.some(s => !session.scopes.includes(s))) throw new AuthFailure(400, 'invalid_request', 'scope_not_granted');
    jsonResponse(res, 200, store.createPairing(input));
  } else if (key === 'GET /api/auth/pairing-links') {
    jsonResponse(res, 200, store.pairingLinks());
  } else if (key === 'POST /api/auth/pairing-links/revoke') {
    const input = await body(req);
    if (typeof input.id !== 'string') throw new AuthFailure(400, 'invalid_request', 'invalid_command');
    jsonResponse(res, 200, { revoked: store.revokePairing(input.id) });
  } else if (key === 'GET /api/auth/clients') {
    jsonResponse(res, 200, store.clients(session.sessionId));
  } else if (key === 'POST /api/auth/clients/revoke') {
    const input = await body(req);
    if (typeof input.sessionId !== 'string') throw new AuthFailure(400, 'invalid_request', 'invalid_command');
    if (input.sessionId === session.sessionId) {
      throw new AuthFailure(403, 'operation_forbidden', 'current_session_revoke_not_allowed');
    }
    jsonResponse(res, 200, { revoked: store.revoke(input.sessionId) });
  } else {
    const victims = store.clients().filter(s => s.sessionId !== session.sessionId);
    // One transaction, not partially completed per-device writes.
    store.commit(store.state.sessions.filter(s => s.sessionId === session.sessionId));
    for (const [key, value] of store.tickets) if (value.sessionId !== session.sessionId) store.tickets.delete(key);
    jsonResponse(res, 200, { revokedCount: victims.length });
  }
  return true;
}

export function authError(res, error) {
  if (error instanceof AuthFailure) jsonResponse(res, error.status, error.body);
  else jsonResponse(res, 500, { _tag: 'EnvironmentInternalError', code: 'internal_error', reason: 'internal_error', traceId: 'unavailable' });
}
