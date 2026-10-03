import fs from 'node:fs';
import path from 'node:path';

const routes = new Set(['/.well-known/t3/environment', '/oauth/token', '/ws',
  '/api/auth/session', '/api/auth/websocket-ticket', '/api/t3-connect/health',
  '/api/connect/mint-credential', '/api/t3-connect/mint-credential']);
export function connectionRoute(url) {
  const pathname = url.split('?')[0];
  return routes.has(pathname) ? pathname : null;
}
function appendPrivateLog(file, line, maxBytes) {
  if (!file) return;
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_APPEND | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) || stat.nlink !== 1) return;
    if (stat.size + Buffer.byteLength(line) > maxBytes) {
      fs.closeSync(fd); fd = undefined;
      fs.renameSync(file, file + '.1');
      fd = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    }
    fs.writeSync(fd, line);
  } catch { /* Logging failures must not interrupt the connector/authentication. */ }
  finally { if (fd !== undefined) fs.closeSync(fd); }
}

// UI/RPC summaries omit payloads. The separate local connector log preserves
// full network error text, IPs, TLS errors, edge locations and retry timings.
export function createConnectionDiagnostics(directory) {
  const entries = [];
  const file = directory && path.join(directory, 'connection-diagnostics.log');
  const connectorFile = directory && path.join(directory, 'tunnel-connector.log');
  return {
    get summary() { return entries.join('\n'); },
    recordConnectorOutput(pid, output) {
      if (!Number.isInteger(pid) || typeof output !== 'string') return;
      const line = `${new Date().toISOString()} cloudflared ${JSON.stringify({ pid, output: output.slice(0, 64 * 1024) })}\n`;
      appendPrivateLog(connectorFile, line, 2 * 1024 * 1024);
    },
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
      appendPrivateLog(file, line + '\n', 256 * 1024);
      if (event.startsWith('tunnel-') || event === 'server-port') {
        appendPrivateLog(connectorFile, line + '\n', 2 * 1024 * 1024);
      }
    },
  };
}
