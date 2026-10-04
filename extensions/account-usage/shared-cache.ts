import { createHash, randomUUID } from "node:crypto";
import {
  chmodSync,
  closeSync,
  fstatSync,
  mkdirSync,
  openSync,
  readSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import { acquireCacheLock, releaseCacheLock } from "./cache-lock.js";
import { withDeadline } from "./deadline.js";
import {
  serializeBoundedCache,
  type CacheDocument,
  type CacheEntry,
} from "./cache-capacity.js";

const CACHE_PATH = join(getAgentDir(), "account-usage-shared-cache.json");
const MAX_CACHE_BYTES = 1024 * 1024;

/**
 * Coalesce queries within a provider, but let unrelated providers query concurrently.
 * The document lock is held only for reading/merging, never across network I/O.
 */
export async function readThroughSharedCache<T>(options: {
  namespace: string;
  key: string;
  maxAgeMs: number;
  force: boolean;
  signal: AbortSignal;
  query: (signal: AbortSignal) => Promise<T>;
  /** Total network work per publication, excluding lock acquisition. */
  queryTimeoutMs?: number;
  validate?: (value: unknown) => boolean;
}): Promise<T> {
  options.signal.throwIfAborted();
  if (!Number.isSafeInteger(options.maxAgeMs) || options.maxAgeMs < 0)
    throw new RangeError("Invalid cache freshness interval");
  const queryTimeoutMs = options.queryTimeoutMs ?? 120_000;
  if (
    !Number.isSafeInteger(queryTimeoutMs) ||
    queryTimeoutMs < 1 ||
    queryTimeoutMs > 2_147_483_647
  )
    throw new RangeError("Invalid cache query timeout");
  mkdirSync(getAgentDir(), { recursive: true, mode: 0o700 });
  // Atomic replacement makes this unlocked baseline read safe. A forced waiter
  // may reuse a snapshot published AFTER it started, never the preexisting one.
  const initialRevision = options.force
    ? readCache().entries[options.namespace]?.revision
    : undefined;
  let compromised: Error | undefined;
  const namespacePath = `${CACHE_PATH}.${createHash("sha256").update(options.namespace).digest("hex")}`;
  const release = await acquireCacheLock(namespacePath, options.signal, {
    // Never throw from proper-lockfile's heartbeat timer. A throw there bypasses
    // this async function and terminates the entire Pi RPC process.
    onCompromised: (error) => {
      compromised = new Error("额度共享缓存锁已失效，已取消本次缓存写入。", {
        cause: error,
      });
    },
  });
  const throwIfCompromised = () => {
    if (compromised) throw compromised;
  };
  try {
    options.signal.throwIfAborted();
    const cached = await withDocumentLock(
      options.signal,
      () => readCache().entries[options.namespace],
    );
    if (
      (!options.force ||
        (cached?.revision !== undefined &&
          cached.revision !== initialRevision)) &&
      cached?.key === options.key &&
      cached.updatedAt <= Date.now() &&
      Date.now() - cached.updatedAt < options.maxAgeMs &&
      (!options.validate || options.validate(cached.value))
    ) {
      throwIfCompromised();
      return structuredClone(cached.value) as T;
    }

    // Release the namespace lease even if an adapter ignores cancellation.
    // Late results must never overwrite a newer publication.
    const value = await withDeadline(
      options.query,
      options.signal,
      queryTimeoutMs,
    );
    options.signal.throwIfAborted();
    throwIfCompromised();
    if (options.validate && !options.validate(value))
      throw new Error("额度查询返回结构无效，未更新共享缓存。");
    await withDocumentLock(options.signal, () => {
      options.signal.throwIfAborted();
      throwIfCompromised();
      // Another provider may have published while our network request was in flight.
      const document = readCache();
      document.entries[options.namespace] = {
        key: options.key,
        updatedAt: Date.now(),
        revision: randomUUID(),
        value,
      };
      writeCache(document, options.namespace);
    });
    return value;
  } finally {
    await releaseCacheLock(release, () => compromised);
  }
}

async function withDocumentLock<T>(
  signal: AbortSignal,
  operation: () => T,
): Promise<T> {
  let compromised: Error | undefined;
  const release = await acquireCacheLock(CACHE_PATH, signal, {
    onCompromised: (error) => {
      compromised = error;
    },
  });
  try {
    signal.throwIfAborted();
    if (compromised) throw compromised;
    return operation();
  } finally {
    await releaseCacheLock(release, () => compromised);
  }
}

function readCache(): CacheDocument {
  try {
    const value = JSON.parse(readBoundedCache()) as unknown;
    if (!isRecord(value) || value.version !== 1 || !isRecord(value.entries)) {
      return { version: 1, entries: Object.create(null) };
    }
    const entries: Record<string, CacheEntry> = Object.create(null);
    for (const [namespace, raw] of Object.entries(value.entries)) {
      if (
        isRecord(raw) &&
        typeof raw.key === "string" &&
        typeof raw.updatedAt === "number" &&
        Number.isFinite(raw.updatedAt) &&
        raw.updatedAt >= 0 &&
        Object.hasOwn(raw, "value")
      ) {
        entries[namespace] = {
          key: raw.key,
          updatedAt: raw.updatedAt,
          ...(typeof raw.revision === "string"
            ? { revision: raw.revision }
            : {}),
          value: raw.value,
        };
      }
    }
    return { version: 1, entries };
  } catch {
    return { version: 1, entries: Object.create(null) };
  }
}

// Bound allocation and reads even if an external writer grows the file after fstat.
function readBoundedCache(): string {
  const fd = openSync(CACHE_PATH, "r");
  try {
    const info = fstatSync(fd);
    if (!info.isFile() || info.size > MAX_CACHE_BYTES)
      throw new Error("额度共享缓存过大或不是普通文件。");
    const buffer = Buffer.alloc(MAX_CACHE_BYTES + 1);
    let size = 0;
    for (;;) {
      const count = readSync(fd, buffer, size, buffer.length - size, null);
      size += count;
      if (size > MAX_CACHE_BYTES) throw new Error("额度共享缓存过大。");
      if (count === 0) return buffer.subarray(0, size).toString("utf8");
    }
  } finally {
    closeSync(fd);
  }
}

function writeCache(document: CacheDocument, protectedNamespace: string): void {
  const temporaryPath = `${CACHE_PATH}.${process.pid}.${randomUUID()}.tmp`;
  try {
    const serialized = serializeBoundedCache(
      document,
      protectedNamespace,
      MAX_CACHE_BYTES,
    );
    writeFileSync(temporaryPath, serialized, {
      encoding: "utf8",
      mode: 0o600,
      flag: "wx",
    });
    renameSync(temporaryPath, CACHE_PATH);
    chmodSync(CACHE_PATH, 0o600);
  } catch (error) {
    // Cleanup must not mask the original write/rename failure.
    try {
      unlinkSync(temporaryPath);
    } catch {
      // The rename may have succeeded, or the filesystem may be unavailable.
    }
    throw error;
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
