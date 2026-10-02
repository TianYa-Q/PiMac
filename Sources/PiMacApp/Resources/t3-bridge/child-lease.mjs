import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';

// BSD flock lives on the open file description, not on a PID file. lockf's
// descriptor mode locks the inherited description; Node retains it until exit,
// including SIGKILL. Never unlink the lock file (that would split ownership).
export function acquireChildLease(authFile, { waitSeconds = 0 } = {}) {
  if (!Number.isInteger(waitSeconds) || waitSeconds < 0 || waitSeconds > 15) throw new Error('Invalid lease timeout');
  if (!authFile) return () => {};
  const dir = path.dirname(authFile);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const info = fs.lstatSync(dir);
  if (!info.isDirectory() || info.uid !== process.getuid?.()) throw new Error('Unsafe child lease directory');
  fs.chmodSync(dir, 0o700);
  const lock = path.join(dir, 'child-owner.lock');
  const fd = fs.openSync(lock, fs.constants.O_RDWR | fs.constants.O_CREAT | fs.constants.O_NOFOLLOW, 0o600);
  const file = path.join(dir, 'child-owner.json');
  let owned, released = false;
  try {
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid()) throw new Error('Unsafe child lock');
    fs.fchmodSync(fd, 0o600);
    const result = spawnSync('/usr/bin/lockf', ['-s', '-t', String(waitSeconds), '3'], {
      stdio: ['ignore', 'ignore', 'ignore', fd], timeout: (waitSeconds + 5) * 1000,
    });
    if (result.error || result.status !== 0) throw new Error('Server state already owned');
    // Upgrade old PID-only leases conservatively: never replace a live or
    // unclassifiable legacy owner. A proven dead owner's marker is archived.
    if (fs.existsSync(file)) {
      const stat = fs.lstatSync(file);
      if (!stat.isFile() || stat.uid !== process.getuid() || stat.size > 1024) throw new Error('Unsafe child marker');
      const { pid, leaseVersion } = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (!Number.isSafeInteger(pid) || pid <= 0) throw new Error('Invalid child owner');
      // Version 2 always held this kernel lock. Its free lock proves it has
      // exited, even if its PID was subsequently reused by an unrelated app.
      if (leaseVersion !== 2) {
        try { process.kill(pid, 0); throw new Error('Legacy server still alive'); }
        catch (error) { if (error.code !== 'ESRCH') throw error; }
      }
      fs.renameSync(file, `${file}.stale-${randomUUID()}`);
    }
    const marker = fs.openSync(file, fs.constants.O_WRONLY | fs.constants.O_CREAT | fs.constants.O_EXCL | fs.constants.O_NOFOLLOW, 0o600);
    try {
      owned = fs.fstatSync(marker);
      fs.writeFileSync(marker, JSON.stringify({ pid: process.pid, nonce: randomUUID(), leaseVersion: 2 }));
      fs.fsyncSync(marker);
    } finally { fs.closeSync(marker); }
  } catch (error) { fs.closeSync(fd); throw error; }
  return () => {
    if (released) return;
    released = true;
    try {
      const current = fs.lstatSync(file);
      if (current.ino === owned.ino && current.dev === owned.dev) fs.unlinkSync(file);
    } catch { /* The diagnostic marker is not the lock. */ }
    fs.closeSync(fd);
  };
}
