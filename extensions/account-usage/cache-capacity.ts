export type CacheEntry = {
  key: string;
  updatedAt: number;
  /** Unique publication identity; legacy snapshots without it remain readable. */
  revision?: string;
  value: unknown;
};

export type CacheDocument = {
  version: 1;
  entries: Record<string, CacheEntry>;
};

/** Evict oldest snapshots only under size pressure. Never evict the new snapshot,
 * mutate the caller's document, or discard old data for an oversized new value.
 */
export function serializeBoundedCache(
  document: CacheDocument,
  protectedNamespace: string,
  maxBytes: number,
): string {
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1)
    throw new RangeError("Invalid cache size limit");
  if (!Object.hasOwn(document.entries, protectedNamespace))
    throw new Error("Missing new cache snapshot");
  const entries: Record<string, CacheEntry> = Object.create(null);
  const encoded = Object.entries(document.entries).map(
    ([namespace, entry]) => ({
      namespace,
      entry,
      bytes: Buffer.byteLength(
        `${JSON.stringify(namespace)}:${JSON.stringify(entry)}`,
      ),
    }),
  );
  const protectedEntry = encoded.find(
    ({ namespace }) => namespace === protectedNamespace,
  )!;
  const overhead = Buffer.byteLength('{"version":1,"entries":{}}\n');
  if (overhead + protectedEntry.bytes > maxBytes)
    throw new Error("额度共享缓存过大，未写入。");
  let size =
    overhead +
    encoded.reduce((sum, entry) => sum + entry.bytes, 0) +
    Math.max(0, encoded.length - 1);
  const evicted = new Set<string>();
  const candidates = encoded
    .filter(({ namespace }) => namespace !== protectedNamespace)
    .sort((a, b) => a.entry.updatedAt - b.entry.updatedAt);
  for (const candidate of candidates) {
    if (size <= maxBytes) break;
    evicted.add(candidate.namespace);
    size -= candidate.bytes + 1;
  }
  for (const { namespace, entry } of encoded) {
    if (!evicted.has(namespace)) entries[namespace] = entry;
  }
  return `${JSON.stringify({ version: 1, entries })}\n`;
}
