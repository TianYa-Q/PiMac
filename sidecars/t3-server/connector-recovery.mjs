// A live connector can sit in exponential retry backoff with every edge down.
// Reset only that connector, never the Server/tunnel identity. A finite budget
// prevents this optimization becoming a crash loop during a real outage.
export function createConnectorRecovery({
  outageMs = 30_000, cooldownMs = 120_000, stableMs = 60_000,
  maxResets = 2, pollIntervalMs = 5_000,
} = {}) {
  let pid = null, downSince = null, healthySince = null;
  let lastReset = -Infinity, resets = 0;
  return {
    pollIntervalMs,
    observe(sourcePID, connected, now) {
      if (sourcePID !== pid) {
        pid = sourcePID; downSince = null; healthySince = null;
      }
      if (connected) {
        downSince = null;
        healthySince ??= now;
        if (now - healthySince >= stableMs) resets = 0;
        return false;
      }
      healthySince = null;
      downSince ??= now;
      if (now - downSince < outageMs || now - lastReset < cooldownMs || resets >= maxResets) return false;
      lastReset = now; resets++;
      return true;
    },
  };
}
