import fs from 'node:fs';
import path from 'node:path';
import net from 'node:net';
import { randomUUID } from 'node:crypto';

const filename = 'loopback-port.json';
const validPort = port => Number.isInteger(port) && port >= 1024 && port <= 65535;

// The gateway's kernel lease serializes callers. Never expose a LAN listener,
// follow symlinks, or rewrite state until the official Server actually listens.
function readPort(directory) {
  const file = path.join(directory, filename);
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) || stat.nlink !== 1 || stat.size > 128) {
      throw new Error('Unsafe loopback port state');
    }
    const value = JSON.parse(fs.readFileSync(fd, 'utf8'));
    if (value.version !== 1 || !validPort(value.port)) throw new Error('Invalid loopback port state');
    return value.port;
  } catch (error) {
    if (error.code === 'ENOENT') return 0;
    throw error;
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}

function availablePort(port) {
  return new Promise((resolve, reject) => {
    const socket = net.createServer();
    socket.once('error', reject);
    socket.listen({ host: '127.0.0.1', port, exclusive: true }, () => {
      const selected = socket.address().port;
      socket.close(error => error ? reject(error) : resolve(selected));
    });
  });
}

export async function prepareServerPort(directory, diagnostics) {
  const saved = readPort(directory);
  let port;
  try { port = await availablePort(saved); }
  catch (error) {
    if (!saved || error.code !== 'EADDRINUSE') throw error;
    // Do not kill the owner or send a probe to it. Re-registration is necessary
    // only for this exceptional case, not on every restart.
    port = await availablePort(0);
    diagnostics?.record('server-port', { reason: 'occupied-reassigned' });
  }
  if (!validPort(port)) throw new Error('Invalid selected loopback port');
  diagnostics?.record('server-port', { reason: saved === port ? 'reused' : 'selected' });
  return {
    port,
    commit(listeningPort) {
      // The probe cannot transfer its fd to upstream. A bind race must fail
      // startup, not silently save a different origin or contact the new owner.
      if (listeningPort !== port) throw new Error('Unexpected Server listening port');
      const temporary = path.join(directory, `${filename}.${randomUUID()}.tmp`);
      try {
        const fd = fs.openSync(temporary, 'wx', 0o600);
        try {
          fs.writeFileSync(fd, JSON.stringify({ version: 1, port }) + '\n');
          fs.fsyncSync(fd);
        } finally { fs.closeSync(fd); }
        fs.renameSync(temporary, path.join(directory, filename));
      } finally { fs.rmSync(temporary, { force: true }); }
    },
  };
}
