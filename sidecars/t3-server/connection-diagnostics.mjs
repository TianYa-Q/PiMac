import fs from 'node:fs';
import path from 'node:path';

const routes = new Set(['/.well-known/t3/environment', '/oauth/token', '/ws',
  '/api/auth/session', '/api/auth/websocket-ticket', '/api/t3-connect/health',
  '/api/connect/mint-credential', '/api/t3-connect/mint-credential']);
export function connectionRoute(url) {
  const pathname = url.split('?')[0];
  return routes.has(pathname) ? pathname : null;
}
// Never accept arbitrary errors, headers, URLs or payloads here: they can carry
// tokens, DPoP proofs, pairing codes and workspace data.
export function createConnectionDiagnostics(directory) {
  const entries = [];
  const file = directory && path.join(directory, 'connection-diagnostics.log');
  return {
    get summary() { return entries.join('\n'); },
    record(event, fields = {}) {
      const safe = {};
      for (const key of ['route', 'method', 'transport', 'status', 'reason', 'origin']) {
        if (fields[key] !== undefined) safe[key] = fields[key];
      }
      // RPC metadata must be bounded identifiers/enums, never arbitrary text.
      for (const key of ['commandId', 'commandType', 'threadId', 'dispatchMode', 'deliveryIntent', 'errorTags']) {
        const value = fields[key];
        if (typeof value === 'string' && value.length <= 384 && /^[A-Za-z0-9_.:/%\-]+$/.test(value)) safe[key] = value;
      }
      const line = `${new Date().toISOString()} ${event} ${JSON.stringify(safe)}`;
      entries.push(line); if (entries.length > 20) entries.shift();
      if (file) {
        try {
          if (fs.existsSync(file) && fs.statSync(file).size > 256 * 1024) fs.renameSync(file, file + '.1');
          fs.appendFileSync(file, line + '\n', { mode: 0o600 });
        } catch { /* Diagnostics must not break authentication. */ }
      }
    },
  };
}
