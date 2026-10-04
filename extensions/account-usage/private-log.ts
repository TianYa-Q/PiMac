import {
  closeSync,
  constants,
  fchmodSync,
  fstatSync,
  lstatSync,
  mkdirSync,
  openSync,
  renameSync,
  writeFileSync,
} from "node:fs";
import { dirname } from "node:path";

export const MAX_DIAGNOSTIC_LOG_BYTES = 1024 * 1024;
export const MAX_DIAGNOSTIC_RECORD_BYTES = 16 * 1024;

function checkEntry(path: string): void {
  try {
    const entry = lstatSync(path);
    if (!entry.isFile() || entry.isSymbolicLink() || entry.nlink !== 1)
      throw new Error("Diagnostic log must be a private regular file");
  } catch (error) {
    if (!(error instanceof Error && "code" in error && error.code === "ENOENT"))
      throw error;
  }
}

/** No-follow/nonblocking opens prevent logs from modifying linked targets or hanging on FIFOs.
 * O_APPEND avoids overwriting concurrent appends; short writes may still split records.
 * Rotation is best-effort across processes; diagnostics are not a transactional audit log.
 */
export function appendPrivateDiagnostic(path: string, record: unknown): void {
  const line = `${JSON.stringify(record)}\n`;
  const bytes = Buffer.byteLength(line);
  if (bytes > MAX_DIAGNOSTIC_RECORD_BYTES)
    throw new Error("Diagnostic record exceeds size limit");
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  checkEntry(path);
  let descriptor: number | undefined;
  try {
    const open = () => {
      const fd = openSync(
        path,
        constants.O_WRONLY |
          constants.O_APPEND |
          constants.O_CREAT |
          constants.O_NOFOLLOW |
          constants.O_NONBLOCK,
        0o600,
      );
      try {
        const info = fstatSync(fd);
        if (!info.isFile() || info.nlink !== 1)
          throw new Error("Diagnostic log must be a private regular file");
        fchmodSync(fd, 0o600);
        return fd;
      } catch (error) {
        closeSync(fd);
        throw error;
      }
    };
    descriptor = open();
    const info = fstatSync(descriptor);
    if (info.size + bytes > MAX_DIAGNOSTIC_LOG_BYTES) {
      const current = lstatSync(path);
      if (current.dev !== info.dev || current.ino !== info.ino)
        throw new Error("Diagnostic log changed during rotation");
      closeSync(descriptor);
      descriptor = undefined;
      renameSync(path, `${path}.1`);
      checkEntry(path);
      descriptor = open();
    }
    writeFileSync(descriptor, line, "utf8");
  } finally {
    if (descriptor !== undefined) closeSync(descriptor);
  }
}
