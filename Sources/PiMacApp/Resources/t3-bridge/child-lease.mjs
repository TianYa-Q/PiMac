import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

// Parent flock alone is insufficient when the parent crashes before the child
// consumes stdin EOF. This exclusive marker lasts until the actual Node exit.
// Never automatically steal stale markers: SIGKILL recovery is an operator
// action, not permission for a replacement to become a concurrent writer.
export function acquireChildLease(authFile) {
  if (!authFile) return () => {};
  const dir = path.dirname(authFile);
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const info = fs.lstatSync(dir);
  if (!info.isDirectory() || info.uid !== process.getuid?.()) throw new Error('Unsafe child lease directory');
  fs.chmodSync(dir, 0o700);
  const file = path.join(dir, 'child-owner.json');
  const fd = fs.openSync(file, 'wx', 0o600);
  let owned;
  try {
    owned = fs.fstatSync(fd);
    fs.writeFileSync(fd, JSON.stringify({ pid: process.pid, nonce: randomUUID() }));
    fs.fsyncSync(fd);
  } finally { fs.closeSync(fd); }
  return () => {
    try {
      const current = fs.lstatSync(file);
      if (current.ino === owned.ino && current.dev === owned.dev) fs.unlinkSync(file);
    } catch { /* An unsafe/unremovable marker remains fail-closed. */ }
  };
}
