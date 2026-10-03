import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { parsePiUsage, collectPiUsage, readPiLimitSources } from '../pi-mobile-usage.mjs';

const entry = { type: 'message', id: 'msg-1', timestamp: '2026-01-01T01:00:00Z', message: {
  role: 'assistant', provider: 'openai-codex', model: 'gpt-test', timestamp: Date.parse('2026-01-01T01:00:00Z'),
  usage: { input: 100, output: 20, cacheRead: 30, cacheWrite: 10, cost: { total: 0.25 } },
} };
test('Pi usage reads final assistant usage without summing cached tokens into uncached input', () => {
  const record = parsePiUsage(entry, 'session');
  assert.equal(record.provider, 'codex');
  assert.deepEqual(record.totals, { uncachedInputTokens: 100, cachedInputTokens: 30,
    cacheCreationTokens: 10, outputTokens: 20, reasoningTokens: 0 });
  assert.equal(record.reportedCostUsd, 0.25);
  assert.equal(record.dedupeKey, 'pi:msg-1:' + entry.message.timestamp);
  assert.equal(parsePiUsage({ ...entry, message: { role: 'user' } }, 'session'), null);
  assert.equal(parsePiUsage({ ...entry, message: { ...entry.message, provider: 'unknown' } }, 'session'), null);
});
test('Pi scanner reads only sessions, ignores symlinks and preserves fork entry dedupe keys', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-usage-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, 'sessions', 'workspace'), { recursive: true });
  const transcript = id => [JSON.stringify({ type: 'session', id }), JSON.stringify(entry)].join('\n');
  await writeFile(join(directory, 'sessions', 'workspace', 'a.jsonl'), transcript('first'));
  await writeFile(join(directory, 'sessions', 'workspace', 'fork.jsonl'), transcript('fork'));
  await writeFile(join(directory, 'unrelated.jsonl'), transcript('unrelated'));
  await symlink(join(directory, 'unrelated.jsonl'), join(directory, 'sessions', 'link.jsonl'));
  const sources = await collectPiUsage({ agentDirectory: directory });
  assert.equal(sources.length, 1);
  assert.equal(sources[0].files.length, 2);
  assert.equal(new Set(sources[0].files.flatMap(file => file.records.map(row => row.dedupeKey))).size, 1);
  assert.equal(sources[0].dir, join(directory, 'sessions'));
});
test('Pi limits converts remaining to used and seconds/ms resets without exposing credentials', async () => {
  const secret = 'private-token';
  const sources = await readPiLimitSources({ accountStatus: async ({ provider }) => provider === 'antigravity'
    ? { gemini: { kind: 'loaded', quotas: [{ remainingPercent: 60, resetAt: 1767225600000, window: 'weekly' }] } }
    : { accounts: provider === 'openai' ? [] : [{ name: 'work', access: secret,
      primary: { remainingPercent: 75, resetAt: 1767225600, windowSeconds: 18000 },
      secondary: { remainingPercent: 40, windowSeconds: 604800 } }, { name: 'hidden', hidden: true }] },
  }, () => 1767225600000);
  const rows = sources[0].accounts;
  assert.equal(rows.length, 2);
  assert.equal(rows[0].usageLimits.windows[0].usedPercent, 25);
  assert.equal(rows[0].usageLimits.windows[0].kind, 'session');
  assert.equal(rows[0].usageLimits.windows[1].kind, 'weekly');
  assert.equal(rows[1].usageLimits.windows[0].resetsAt, rows[0].usageLimits.windows[0].resetsAt);
  assert.equal(JSON.stringify(sources).includes(secret), false);
});
test('missing or failed Pi quotas stay visible as notices instead of invented bars', async () => {
  const empty = await readPiLimitSources({ accountStatus: async () => ({ accounts: [], gemini: { kind: 'unconfigured' } }) });
  assert.match(empty[0].error, /No Pi OAuth/);
  const failed = await readPiLimitSources({ accountStatus: async () => { throw new Error('private-secret'); } });
  assert.equal(failed[0].accounts.length, 0);
  assert.equal(JSON.stringify(failed).includes('private-secret'), false);
});
