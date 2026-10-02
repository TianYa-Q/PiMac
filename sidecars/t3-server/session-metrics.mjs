// Read-only metrics access to provider-owned runtimes; never launches a process.
const readers = new Map();
export function registerSessionMetrics(threadId, read) {
  readers.set(threadId, read);
  return () => { if (readers.get(threadId) === read) readers.delete(threadId); };
}
export async function sessionMetrics(threadId) {
  const read = readers.get(threadId);
  if (!read) return null;
  const raw = await read();
  const number = value => typeof value === 'number' && Number.isFinite(value) && value >= 0 ? value : null;
  const context = raw.contextUsage;
  return { cost: number(raw.cost), outputTokensPerSecond: number(raw.outputTokensPerSecond), tokens: Object.fromEntries(['input', 'output', 'cacheRead', 'cacheWrite', 'total']
    .map(key => [key, number(raw.tokens?.[key])])), contextUsage: context ? {
      tokens: number(context.tokens), contextWindow: number(context.contextWindow), percent: number(context.percent),
    } : null };
}
export function supportedThinkingLevels(model) {
  if (!model.reasoning) return ['off'];
  return ['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].filter(level => {
    const mapped = model.thinkingLevelMap?.[level];
    return mapped !== null && (!['xhigh', 'max'].includes(level) || mapped !== undefined);
  });
}
