import { randomUUID } from "node:crypto";
import {
  chmodSync,
  closeSync,
  constants,
  fchmodSync,
  fstatSync,
  fsyncSync,
  lstatSync,
  mkdirSync,
  openSync,
  readSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";

export const MAX_PRIVATE_JSON_BYTES = 4 * 1024 * 1024;

/** Never follow links or block on special files; bound bytes actually read, not only stat size. */
export function readPrivateRegularFile(path: string): string {
  // Retain a portable preflight as well as the race-safe POSIX open flags.
  const entry = lstatSync(path);
  if (!entry.isFile() || entry.isSymbolicLink())
    throw new Error(`${path} 必须是普通文件。`);
  const descriptor = openSync(
    path,
    constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
  );
  try {
    const info = fstatSync(descriptor);
    if (!info.isFile()) throw new Error(`${path} 必须是普通文件。`);
    if (info.size > MAX_PRIVATE_JSON_BYTES)
      throw new Error(`${path} 超过账户数据大小限制（4 MiB）。`);
    fchmodSync(descriptor, 0o600);
    // Geometric storage also bounds memory if the filesystem returns tiny partial reads.
    let buffer = Buffer.allocUnsafe(
      Math.min(MAX_PRIVATE_JSON_BYTES + 1, Math.max(4096, info.size + 1)),
    );
    let size = 0;
    for (;;) {
      if (size === buffer.length) {
        const grown = Buffer.allocUnsafe(
          Math.min(MAX_PRIVATE_JSON_BYTES + 1, buffer.length * 2),
        );
        buffer.copy(grown, 0, 0, size);
        buffer = grown;
      }
      const count = readSync(
        descriptor,
        buffer,
        size,
        buffer.length - size,
        null,
      );
      if (count === 0) break;
      size += count;
      if (size > MAX_PRIVATE_JSON_BYTES)
        throw new Error(`${path} 超过账户数据大小限制（4 MiB）。`);
    }
    try {
      return new TextDecoder("utf-8", { fatal: true }).decode(
        buffer.subarray(0, size),
      );
    } catch {
      throw new Error(`${path} 不是有效 UTF-8 文件。`);
    }
  } finally {
    closeSync(descriptor);
  }
}

/** Serialize before touching disk, then flush and atomically replace; clean up even partial writes. */
export function writePrivateJson(path: string, value: unknown): void {
  const text = `${JSON.stringify(value, null, 2)}\n`;
  if (Buffer.byteLength(text) > MAX_PRIVATE_JSON_BYTES)
    throw new Error(`${path} 超过账户数据大小限制（4 MiB）。`);
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  chmodSync(dirname(path), 0o700);
  const temporaryPath = `${path}.${randomUUID()}.tmp`;
  let descriptor: number | undefined;
  let created = false;
  try {
    descriptor = openSync(temporaryPath, "wx", 0o600);
    created = true;
    writeFileSync(descriptor, text, "utf8");
    fsyncSync(descriptor);
    closeSync(descriptor);
    descriptor = undefined;
    renameSync(temporaryPath, path);
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
    if (created) {
      try {
        unlinkSync(temporaryPath);
      } catch {
        // Successful rename or cleanup failure must not mask the original error.
      }
    }
  }
}
