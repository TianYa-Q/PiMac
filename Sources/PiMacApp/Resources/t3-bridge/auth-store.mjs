import { createHash, randomBytes, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { AUTH_DESCRIPTOR, DEFAULT_SCOPES, SCOPES, ACCESS_TOKEN_TYPE,
  BOOTSTRAP_TOKEN_TYPE, TOKEN_EXCHANGE_GRANT } from './protocol.mjs';

const iso = ms => new Date(ms).toISOString();
const digest = value => createHash('sha256').update(value).digest('hex');
const secret = () => randomBytes(32).toString('hex');
const MAX_SESSIONS = 256;

export class AuthFailure extends Error {
  constructor(status, code, reason, extra = {}) {
    super(reason);
    this.status = status;
    const tags = { auth_invalid: 'EnvironmentAuthInvalidError', invalid_request: 'EnvironmentRequestInvalidError',
      insufficient_scope: 'EnvironmentScopeRequiredError', operation_forbidden: 'EnvironmentOperationForbiddenError',
      internal_error: 'EnvironmentInternalError' };
    this.body = { _tag: tags[code], code, ...(code === 'insufficient_scope' ? {} : { reason }),
      traceId: randomUUID(), ...extra };
  }
}
const invalid = () => new AuthFailure(401, 'auth_invalid', 'invalid_credential');
const badRequest = reason => new AuthFailure(400, 'invalid_request', reason);
function scopes(value, fallback = DEFAULT_SCOPES) {
  const selected = value === undefined ? [...fallback] : value;
  if (!Array.isArray(selected) || selected.length === 0 ||
      new Set(selected).size !== selected.length || selected.some(x => !SCOPES.includes(x))) {
    throw badRequest('invalid_scope');
  }
  return [...selected];
}
function label(value) {
  if (value === undefined) return undefined;
  if (typeof value !== 'string' || !value.trim() || value.length > 128) throw badRequest('invalid_command');
  return value.trim();
}

/// Single-process store. Pairing credentials and WS tickets never survive process restart.
/// High-entropy device credentials are persisted only as SHA-256 digests.
export class AuthStore {
  constructor({ file, now = Date.now, sessionTtlMs = 30 * 24 * 3600_000,
    pairingTtlMs = 5 * 60_000, ticketTtlMs = 30_000 } = {}) {
    this.file = file;
    this.now = now;
    this.sessionTtlMs = sessionTtlMs;
    this.pairingTtlMs = pairingTtlMs;
    this.ticketTtlMs = ticketTtlMs;
    this.grants = new Map();
    this.tickets = new Map();
    this.listeners = new Set();
    this.connections = new Map();
    this.state = { version: 1, environmentId: randomUUID(), sessions: [] };
    if (file && fs.existsSync(file)) {
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.size > 2 * 1024 * 1024 || stat.uid !== process.getuid?.()) {
        throw new Error('Unsafe auth state file');
      }
      const value = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (!this.validState(value)) throw new Error('Invalid auth state; refusing to overwrite');
      fs.chmodSync(file, 0o600);
      this.state = value;
    } else if (file) {
      this.persist(this.state);
    }
  }

  validState(value) {
    return value?.version === 1 && typeof value.environmentId === 'string' &&
      /^[0-9a-f-]{36}$/.test(value.environmentId) && Array.isArray(value.sessions) &&
      value.sessions.length <= MAX_SESSIONS && value.sessions.every(s =>
        /^[0-9a-f]{64}$/.test(s.hash) && typeof s.sessionId === 'string' &&
        Number.isFinite(s.issuedAt) && Number.isFinite(s.expiresAt) &&
        s.client && typeof s.client === 'object' && typeof s.client.deviceType === 'string' &&
        typeof s.subject === 'string' && Array.isArray(s.scopes) &&
        s.scopes.length > 0 && s.scopes.every(x => SCOPES.includes(x))) &&
      new Set(value.sessions.map(s => s.hash)).size === value.sessions.length &&
      new Set(value.sessions.map(s => s.sessionId)).size === value.sessions.length;
  }

  persist(value) {
    if (!this.file) return;
    const directory = path.dirname(this.file);
    fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
    const stat = fs.lstatSync(directory);
    if (!stat.isDirectory() || stat.uid !== process.getuid?.()) throw new Error('Unsafe auth directory');
    fs.chmodSync(directory, 0o700);
    const temp = `${this.file}.${randomUUID()}.tmp`;
    let fd;
    try {
      fd = fs.openSync(temp, 'wx', 0o600);
      fs.writeFileSync(fd, JSON.stringify(value));
      fs.fsyncSync(fd);
      fs.closeSync(fd);
      fd = undefined;
      fs.renameSync(temp, this.file);
      const dirfd = fs.openSync(directory, 'r');
      try { fs.fsyncSync(dirfd); } finally { fs.closeSync(dirfd); }
    } finally {
      if (fd !== undefined) fs.closeSync(fd);
      if (fs.existsSync(temp)) fs.unlinkSync(temp);
    }
  }

  commit(sessions) {
    const next = { ...this.state, sessions };
    if (this.failed) throw new Error('Auth store unavailable');
    try { this.persist(next); }
    catch (error) {
      // The rename may have succeeded before a durability error. Fail closed instead
      // of continuing to trust the previous in-memory authorization state.
      this.failed = true;
      this.grants.clear();
      this.tickets.clear();
      this.notify();
      throw error;
    }
    this.state = next;
    this.notify();
  }

  subscribe(listener) {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  notify() {
    for (const listener of this.listeners) {
      try { listener(); } catch { /* A subscriber cannot change a durable commit outcome. */ }
    }
  }

  connected(sessionId) {
    const old = this.connections.get(sessionId);
    this.connections.set(sessionId, { count: (old?.count ?? 0) + 1, at: iso(this.now()) });
  }

  disconnected(sessionId) {
    const old = this.connections.get(sessionId);
    if (!old || old.count <= 1) this.connections.delete(sessionId);
    else old.count--;
  }

  prune() {
    const now = this.now();
    for (const [key, value] of this.grants) if (value.expiresAt <= now) this.grants.delete(key);
    for (const [key, value] of this.tickets) if (value.expiresAt <= now) this.tickets.delete(key);
  }

  createPairing(input = {}) {
    if (this.failed) throw new Error('Auth store unavailable');
    this.prune();
    const granted = scopes(input.scopes);
    const name = label(input.label);
    if (this.grants.size >= 64) throw new AuthFailure(503, 'internal_error', 'pairing_credential_issuance_failed');
    const credential = secret();
    const grant = { id: randomUUID(), scopes: granted, subject: 'paired-client',
      ...(name ? { label: name } : {}), createdAt: this.now(), expiresAt: this.now() + this.pairingTtlMs };
    this.grants.set(digest(credential), grant);
    return { id: grant.id, credential, ...(name ? { label: name } : {}), expiresAt: iso(grant.expiresAt) };
  }

  exchange(input, metadata = {}) {
    this.prune();
    if (input.grant_type !== TOKEN_EXCHANGE_GRANT || input.subject_token_type !== BOOTSTRAP_TOKEN_TYPE ||
        input.requested_token_type !== ACCESS_TOKEN_TYPE || typeof input.subject_token !== 'string' ||
        !/^[0-9a-f]{64}$/.test(input.subject_token)) throw badRequest('invalid_command');
    const hash = digest(input.subject_token);
    const grant = this.grants.get(hash);
    if (!grant) throw invalid();
    if (input.scope !== undefined && typeof input.scope !== 'string') throw badRequest('invalid_scope');
    const selected = scopes(input.scope === undefined ? undefined : input.scope.trim().split(/\s+/), grant.scopes);
    if (selected.some(x => !grant.scopes.includes(x))) throw badRequest('scope_not_granted');
    const clientLabel = grant.label ?? label(input.client_label);
    const deviceType = input.client_device_type ?? 'unknown';
    if (!['desktop', 'mobile', 'tablet', 'bot', 'unknown'].includes(deviceType)) throw badRequest('invalid_command');
    const os = label(input.client_os);
    const token = secret();
    const issuedAt = this.now();
    const session = { hash: digest(token), sessionId: randomUUID(), subject: grant.subject,
      scopes: selected, issuedAt, expiresAt: issuedAt + this.sessionTtlMs,
      client: { deviceType, ...(clientLabel ? { label: clientLabel } : {}),
        ...(os ? { os } : {}), ...metadata } };
    const live = this.state.sessions.filter(s => s.expiresAt > issuedAt);
    if (live.length >= MAX_SESSIONS) throw new AuthFailure(503, 'internal_error', 'access_token_issuance_failed');
    // Commit before returning or consuming the grant. A failed write must not issue an ephemeral token.
    this.commit([...live, session]);
    this.grants.delete(hash);
    return { access_token: token, issued_token_type: ACCESS_TOKEN_TYPE, token_type: 'Bearer',
      expires_in: Math.floor(this.sessionTtlMs / 1000), scope: selected.join(' ') };
  }

  authenticate(header) {
    if (this.failed || typeof header !== 'string' || !/^Bearer [0-9a-f]{64}$/.test(header)) throw invalid();
    const hash = digest(header.slice(7));
    const session = this.state.sessions.find(s => s.hash === hash && s.expiresAt > this.now());
    if (!session) throw invalid();
    return session;
  }

  requireScope(session, scope) {
    if (!session.scopes.includes(scope)) {
      throw new AuthFailure(403, 'insufficient_scope', 'scope_required', { requiredScope: scope });
    }
  }

  sessionState(header) {
    try {
      const session = this.authenticate(header);
      return { authenticated: true, auth: AUTH_DESCRIPTOR, scopes: session.scopes,
        sessionMethod: 'bearer-access-token', expiresAt: iso(session.expiresAt) };
    } catch (error) {
      if (!(error instanceof AuthFailure)) throw error;
      return { authenticated: false, auth: AUTH_DESCRIPTOR };
    }
  }

  isLive(sessionId) {
    if (this.failed) return undefined;
    return this.state.sessions.find(s => s.sessionId === sessionId && s.expiresAt > this.now());
  }

  createTicket(session) {
    this.prune();
    if (!this.isLive(session.sessionId)) throw invalid();
    if (this.tickets.size >= 256) throw new AuthFailure(503, 'internal_error', 'websocket_ticket_issuance_failed');
    const ticket = secret();
    const expiresAt = Math.min(this.now() + this.ticketTtlMs, session.expiresAt);
    this.tickets.set(digest(ticket), { sessionId: session.sessionId, expiresAt });
    return { ticket, expiresAt: iso(expiresAt) };
  }

  consumeTicket(ticket) {
    this.prune();
    if (typeof ticket !== 'string' || !/^[0-9a-f]{64}$/.test(ticket)) throw invalid();
    const hash = digest(ticket);
    const value = this.tickets.get(hash);
    if (!value) throw invalid();
    this.tickets.delete(hash);
    const session = this.isLive(value.sessionId);
    if (!session) throw invalid();
    return session;
  }

  pairingLinks() {
    this.prune();
    return [...this.grants.values()].map(g => ({ ...g, createdAt: iso(g.createdAt), expiresAt: iso(g.expiresAt) }));
  }

  revokePairing(id) {
    for (const [key, value] of this.grants) {
      if (value.id === id) { this.grants.delete(key); return true; }
    }
    return false;
  }

  clients(currentId) {
    return this.state.sessions.filter(s => s.expiresAt > this.now()).map(s => ({
      sessionId: s.sessionId, subject: s.subject, scopes: s.scopes, method: 'bearer-access-token',
      client: s.client, issuedAt: iso(s.issuedAt), expiresAt: iso(s.expiresAt),
      lastConnectedAt: this.connections.get(s.sessionId)?.at ?? null,
      connected: this.connections.has(s.sessionId), current: s.sessionId === currentId,
    }));
  }

  revoke(sessionId) {
    const found = this.state.sessions.some(s => s.sessionId === sessionId);
    if (!found) return false;
    this.commit(this.state.sessions.filter(s => s.sessionId !== sessionId));
    for (const [key, value] of this.tickets) if (value.sessionId === sessionId) this.tickets.delete(key);
    return true;
  }
}
