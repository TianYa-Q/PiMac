import { randomUUID } from "node:crypto";
import {
  chmodSync,
  mkdirSync,
  readFileSync,
  renameSync,
  unlinkSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";
import { setTimeout as delay } from "node:timers/promises";
import { getAgentDir } from "@earendil-works/pi-coding-agent";
import lockfile from "proper-lockfile";

const CACHE_PATH = join(getAgentDir(), "account-usage-shared-cache.json");

type CacheEntry = {
  key: string;
  updatedAt: number;
  value: unknown;
};

type CacheDocument = {
  version: 1;
  entries: Record<string, CacheEntry>;
};

/**
 * Shares quota queries between all Pi RPC processes. The lock is intentionally held while
 * querying: other sessions wait for the first query and then consume exactly the same result.
 */
export async function readThroughSharedCache<T>(options: {
  namespace: string;
  key: string;
  maxAgeMs: number;
  force: boolean;
  signal: AbortSignal;
  query: () => Promise<T>;
}): Promise<T> {
  options.signal.throwIfAborted();
  mkdirSync(getAgentDir(), { recursive: true, mode: 0o700 });
  let compromised: Error | undefined;
  const release = await acquireCacheLock(options.signal, {
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
    const document = readCache();
    const cached = document.entries[options.namespace];
    if (
      !options.force &&
      cached?.key === options.key &&
      cached.updatedAt <= Date.now() &&
      Date.now() - cached.updatedAt < options.maxAgeMs
    ) {
      throwIfCompromised();
      return structuredClone(cached.value) as T;
    }

    const value = await options.query();
    options.signal.throwIfAborted();
    throwIfCompromised();
    document.entries[options.namespace] = {
      key: options.key,
      updatedAt: Date.now(),
      value,
    };
    writeCache(document);
    return value;
  } finally {
    await releaseCacheLock(release, () => compromised);
  }
}

/** Retry outside proper-lockfile so cancellation interrupts contention, not just the query. */
async function acquireCacheLock(
  signal: AbortSignal,
  options: { onCompromised: (error: Error) => void },
): Promise<() => Promise<void>> {
  for (let attempt = 0; ; attempt++) {
    signal.throwIfAborted();
    try {
      // Do not race acquisition against abort: a late successful acquisition would leak its lease.
      return await lockfile.lock(CACHE_PATH, {
        realpath: false,
        stale: 5 * 60_000,
        retries: 0,
        ...options,
      });
    } catch (error) {
      signal.throwIfAborted();
      if (
        (error as NodeJS.ErrnoException).code !== "ELOCKED" ||
        attempt >= 360
      ) {
        throw error;
      }
      await delay(500, undefined, { signal });
    }
  }
}

async function releaseCacheLock(
  release: () => Promise<void>,
  getCompromised: () => Error | undefined,
): Promise<void> {
  // Once compromised, proper-lockfile has already marked this lease released;
  // invoking release() would only produce ERELEASED and hide the useful error.
  try {
    if (!getCompromised()) await release();
  } catch (error) {
    if (!getCompromised()) throw error;
  }
  const compromised = getCompromised();
  if (compromised) throw compromised;
}

function readCache(): CacheDocument {
  try {
    const value = JSON.parse(readFileSync(CACHE_PATH, "utf8")) as unknown;
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
          value: raw.value,
        };
      }
    }
    return { version: 1, entries };
  } catch {
    return { version: 1, entries: Object.create(null) };
  }
}

function writeCache(document: CacheDocument): void {
  const temporaryPath = `${CACHE_PATH}.${process.pid}.${randomUUID()}.tmp`;
  try {
    writeFileSync(temporaryPath, `${JSON.stringify(document)}\n`, {
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
