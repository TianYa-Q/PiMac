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
test('Pi scanner preserves Unicode separators across chunks, CRLF and final unterminated records', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-usage-unicode-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, 'sessions'));
  const withText = (id, text) => ({ ...entry, id, message: { ...entry.message,
    content: [{ type: 'text', text }] } });
  const records = [
    { type: 'session', id: 'unicode-session' },
    withText('large', 'x'.repeat(128 * 1024) + '第一段\u2028第二段\u2029第三段'),
    withText('final', '末尾\u2028记录'),
  ];
  await writeFile(join(directory, 'sessions', 'unicode.jsonl'), records.map(JSON.stringify).join('\r\n'));
  const sources = await collectPiUsage({ agentDirectory: directory });
  assert.equal(sources.length, 1);
  assert.equal(sources[0].status, 'ok');
  assert.equal(sources[0].files[0].records.length, 2);
  assert(sources[0].files[0].records.every(record => record.sessionId === 'unicode-session'));
});
test('Pi scanner still flags malformed JSON and retains valid records after it', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-usage-malformed-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  await mkdir(join(directory, 'sessions'));
  await writeFile(join(directory, 'sessions', 'broken.jsonl'),
    '{"unfinished":\n' + JSON.stringify(entry) + '\n');
  const sources = await collectPiUsage({ agentDirectory: directory });
  assert.equal(sources[0].status, 'partial');
  assert.equal(sources[0].files[0].records.length, 1);
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
test('banked resets reach mobile for both ChatGPT providers with only display metadata', async () => {
  const sources = await readPiLimitSources({ accountStatus: async ({ provider }) =>
    provider === 'antigravity' ? { gemini: { kind: 'unconfigured' } } : { accounts: [
      { name: provider, resetCredits: { availableCount: 2, nextCreditId: 'private-id',
        credits: [{ expiresAt: 1767398400, title: 'private-title' }, { expiresAt: 1767312000 },
          { expiresAt: '1767225600' }, { expiresAt: true }, { expiresAt: Infinity },
          { expiresAt: -1 }, { expiresAt: 8640000000001 }, null] } },
      { name: 'hidden', hidden: true, resetCredits: { availableCount: 99 } },
    ] } }, () => 1767225600000);
  assert.deepEqual(sources[0].accounts.map(row => row.usageLimits.resetCredits), [
    { availableCount: 2, nextExpiresAt: '2026-01-02T00:00:00.000Z' },
    { availableCount: 2, nextExpiresAt: '2026-01-02T00:00:00.000Z' },
  ]);
  assert(sources[0].accounts.every(row => row.usageLimits.windows.length === 0));
  // Stock mobile displays plan in account details/composer even when redeem is null.
  assert(sources[0].accounts.every(row =>
    row.plan === '2 reset credits · 到期（北京时间 UTC+8）：2026-01-02 08:00:00；2026-01-03 08:00:00 (read-only)'));
  assert.equal(JSON.stringify(sources).includes('private-'), false);
  assert.equal(JSON.stringify(sources).includes('resetCreditInput'), false);
});
test('mobile expiry details retain duplicate credits and use Beijing time across date boundaries', async () => {
  const seconds = Date.parse('2026-01-01T20:30:45Z') / 1000;
  const sources = await readPiLimitSources({ accountStatus: async ({ provider }) =>
    provider === 'openai-codex' ? { accounts: [{ name: 'work', resetCredits: {
      availableCount: 3, credits: [{ expiresAt: seconds }, {}, { expiresAt: seconds }],
    } }] } : { accounts: [], gemini: { kind: 'unconfigured' } } });
  const row = sources[0].accounts[0];
  assert.equal(row.usageLimits.resetCredits.nextExpiresAt, '2026-01-01T20:30:45.000Z');
  assert.equal(row.plan, '3 reset credits · 到期（北京时间 UTC+8）：2026-01-02 04:30:45；2026-01-02 04:30:45 (read-only)');
});
test('missing, zero and invalid mobile reset counts do not invent credits or hide quotas', async () => {
  const values = [undefined, null, { availableCount: 0, credits: [{ expiresAt: 1767312000 }] },
    { availableCount: 3 }, { availableCount: 1, credits: [null, {}] },
    ...[-1, 1.5, true, '2', NaN, Infinity, Number.MAX_SAFE_INTEGER + 1].map(availableCount => ({ availableCount }))];
  const sources = await readPiLimitSources({ accountStatus: async ({ provider }) =>
    provider === 'openai-codex' ? { accounts: values.map((resetCredits, index) => ({
      name: `account-${index}`, resetCredits, primary: { remainingPercent: 75 },
    })) } : { accounts: [], gemini: { kind: 'unconfigured' } } });
  assert.deepEqual(sources[0].accounts.map(row => row.usageLimits.resetCredits), [
    undefined, undefined, { availableCount: 0 }, { availableCount: 3 }, { availableCount: 1 },
    ...Array(7).fill(undefined),
  ]);
  assert.deepEqual(sources[0].accounts.map(row => row.plan), [
    undefined, undefined, '0 reset credits (read-only)', '3 reset credits (read-only)',
    '1 reset credit (read-only)', ...Array(7).fill(undefined),
  ]);
  assert(sources[0].accounts.every(row => row.usageLimits.windows[0].usedPercent === 25));
});
test('missing or failed Pi quotas stay visible as notices instead of invented bars', async () => {
  const empty = await readPiLimitSources({ accountStatus: async () => ({ accounts: [], gemini: { kind: 'unconfigured' } }) });
  assert.match(empty[0].error, /No Pi OAuth/);
  const failed = await readPiLimitSources({ accountStatus: async () => { throw new Error('private-secret'); } });
  assert.equal(failed[0].accounts.length, 0);
  assert.equal(JSON.stringify(failed).includes('private-secret'), false);
});
