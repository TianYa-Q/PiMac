// Adapt Pi-owned transcripts and read-only account quotas to the stock mobile contract.
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { createReadStream } from 'node:fs';
import { createPiAccountManagement } from '../../Sources/PiMacApp/Resources/t3-bridge/pi-account-management.mjs';

const providerKinds = { anthropic: 'claude', 'openai-codex': 'codex', openai: 'codex',
  antigravity: 'antigravity', 'google-antigravity': 'antigravity', xai: 'grok' };
const int = value => Number.isSafeInteger(value) && value >= 0 ? value : 0;
export function parsePiUsage(entry, sessionId) {
  const message = entry?.type === 'message' ? entry.message : null;
  if (message?.role !== 'assistant' || !message.usage || !message.model) return null;
  const provider = providerKinds[message.provider];
  const timestampMs = typeof message.timestamp === 'number' ? message.timestamp : Date.parse(entry.timestamp);
  if (!provider || !Number.isFinite(timestampMs)) return null;
  const usage = message.usage;
  return { provider, timestampMs, model: message.model, sessionId,
    totals: { uncachedInputTokens: int(usage.input), cachedInputTokens: int(usage.cacheRead),
      cacheCreationTokens: int(usage.cacheWrite), outputTokens: int(usage.output), reasoningTokens: 0 },
    reportedCostUsd: Number.isFinite(usage.cost?.total) && usage.cost.total >= 0 ? usage.cost.total : null,
    fast: false, dedupeKey: typeof entry.id === 'string' ? `pi:${entry.id}:${timestampMs}` : null };
}

// JSON strings may contain U+2028/U+2029. Node readline treats these as line
// boundaries, but JSONL records are separated only by LF (optionally CRLF).
async function* jsonLines(stream) {
  let fragments = [];
  for await (const chunk of stream) {
    let start = 0;
    for (let end = chunk.indexOf('\n'); end !== -1; end = chunk.indexOf('\n', start)) {
      fragments.push(chunk.slice(start, end));
      yield fragments.join('');
      fragments = [];
      start = end + 1;
    }
    if (start < chunk.length) fragments.push(chunk.slice(start));
  }
  if (fragments.length) yield fragments.join('');
}

export async function collectPiUsage({ agentDirectory = process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), '.pi', 'agent') } = {}) {
  const root = path.join(agentDirectory, 'sessions');
  const groups = new Map();
  let volumeId = '', partial = false;
  try { const stat = await fs.stat(root); volumeId = `${stat.dev}:${stat.ino}`; }
  catch (error) { if (error.code === 'ENOENT') return []; throw new Error('Pi session directory could not be read.'); }
  async function walk(directory) {
    for (const item of await fs.readdir(directory, { withFileTypes: true })) {
      const file = path.join(directory, item.name);
      // Never follow symlinks outside the Pi session tree.
      if (item.isDirectory()) { await walk(file); continue; }
      if (!item.isFile() || !item.name.endsWith('.jsonl')) continue;
      const byProvider = new Map();
      let sessionId = file;
      const stream = createReadStream(file, { encoding: 'utf8' });
      try {
        for await (const line of jsonLines(stream)) {
          let entry;
          try { entry = JSON.parse(line); } catch { partial = true; continue; }
          if (entry.type === 'session' && typeof entry.id === 'string') sessionId = entry.id;
          const record = parsePiUsage(entry, sessionId);
          if (!record) continue;
          if (!byProvider.has(record.provider)) byProvider.set(record.provider, []);
          byProvider.get(record.provider).push(record);
        }
      } catch { partial = true; }
      finally { stream.destroy(); }
      for (const [provider, records] of byProvider) {
        if (!groups.has(provider)) groups.set(provider, []);
        groups.get(provider).push({ path: file, records });
      }
    }
  }
  await walk(root);
  return [...groups].map(([provider, files]) => ({ provider, dir: root, volumeId, files,
    status: partial ? 'partial' : 'ok', message: partial ? 'Some Pi session records could not be read.' : 'Pi session history (not native CLI history).' }));
}

function quotaWindow(value, id, label, milliseconds = false) {
  if (!Number.isFinite(value?.remainingPercent)) return null;
  const duration = value.windowSeconds;
  const kind = duration >= 604800 || /week|7\s*d/i.test(value.window ?? '') ? 'weekly'
    : duration > 0 && duration <= 86400 || /5\s*h|five.?hour/i.test(value.window ?? '') ? 'session' : 'other';
  const reset = value.resetAt * (milliseconds ? 1 : 1000);
  return { id, label: value.window || label, kind,
    usedPercent: 100 - Math.max(0, Math.min(100, value.remainingPercent)),
    ...(Number.isFinite(reset) && reset > 0 && reset <= 8640000000000000 ? { resetsAt: new Date(reset).toISOString() } : {}),
    ...(Number.isFinite(duration) && duration > 0 ? { windowDurationMins: Math.floor(duration / 60) } : {}) };
}
export async function readPiLimitSources(accounts, now = Date.now) {
  const checkedAt = new Date(now()).toISOString();
  const rows = [], errors = [];
  for (const provider of ['openai', 'openai-codex', 'antigravity']) {
    try {
      const result = await accounts.accountStatus({ provider });
      for (const account of result.accounts ?? []) {
        if (account.hidden) continue;
        const windows = [quotaWindow(account.primary, 'primary', 'Session'), quotaWindow(account.secondary, 'secondary', 'Weekly')].filter(Boolean);
        rows.push({ id: `${provider}:${account.name}`, driver: 'codex', email: account.name,
          usageLimits: { checkedAt, windows, ...(account.error ? { unavailable: { reason: 'probeFailed', message: account.error } } : {}) } });
      }
      if (provider === 'antigravity' && result.gemini?.kind !== 'unconfigured') {
        const windows = (result.gemini?.quotas ?? []).map((value, index) => quotaWindow(value, `gemini-${index}`, 'Gemini', true)).filter(Boolean);
        rows.push({ id: 'antigravity', driver: 'antigravity', usageLimits: { checkedAt, windows,
          ...(result.gemini?.error ? { unavailable: { reason: 'probeFailed', message: result.gemini.error } } : {}) } });
      }
    } catch { errors.push('Pi account credentials could not be read.'); }
  }
  // `cliproxy` is the stock client's sole supported multi-account source envelope.
  // No hub is contacted; this is a read-only Pi account projection, labeled as such.
  return [{ id: 'pimac-accounts', kind: 'cliproxy', label: 'Pi accounts (read-only)', checkedAt, accounts: rows,
    ...(errors.length || !rows.length ? { error: errors[0] || 'No Pi OAuth accounts found. API keys do not expose subscription limits.' } : {}) }];
}
export function createPiMobileUsage(options) {
  const accounts = createPiAccountManagement(options);
  return { readLimits: () => readPiLimitSources(accounts), close: () => accounts.close() };
}
