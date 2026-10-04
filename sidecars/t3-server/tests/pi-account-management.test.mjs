import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createPiAccountManagement } from '../../../Sources/PiMacApp/Resources/t3-bridge/pi-account-management.mjs';

function fixture(t, options = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pimac-quota-'));
  let time = 100000, calls = 0;
  const credential = { type: 'oauth', access: 'secret-access', refresh: 'secret-refresh', accountId: 'secret-id', expires: 9999999 };
  const write = (name, value) => fs.writeFileSync(path.join(dir, name), JSON.stringify(value), { mode: 0o600 });
  write('auth.json', { openai: credential });
  const manager = createPiAccountManagement({ agentDirectory: dir, now: () => time,
    fetchImpl: async (_url, input) => {
      calls++; assert.equal(input.redirect, 'error'); assert.equal(input.headers.authorization, 'Bearer secret-access');
      return options.response?.(_url, input) ?? new Response(JSON.stringify({ rate_limit: { primary_window: { used_percent: 25, reset_at: 900, limit_window_seconds: 18000 } }, token: 'server-secret' }));
    } });
  t.after(() => { manager.close(); fs.rmSync(dir, { recursive: true, force: true }); });
  return { dir, write, credential, manager, calls: () => calls, advance: () => { time += 60001; } };
}
test('native OAuth quota is allowlisted and does not claim thread auth or mutate credentials', async t => {
  const f = fixture(t), before = fs.readFileSync(path.join(f.dir, 'auth.json'), 'utf8');
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.equal(result.accounts[0].primary.remainingPercent, 75);
  assert.equal(result.accounts[0].name, 'Pi 已保存授权');
  assert.equal(result.defaultAccount, undefined);
  assert.equal(result.activeAccount, undefined); assert.equal(result.supportsAccountSwitch, false);
  assert.doesNotMatch(JSON.stringify(result), /secret|Bearer|server-secret/);
  assert.equal(fs.readFileSync(path.join(f.dir, 'auth.json'), 'utf8'), before);
});
test('banked resets reach quota cards for both ChatGPT providers without leaking metadata', async t => {
  for (const provider of ['openai', 'openai-codex']) {
    const f = fixture(t, { response: (url, input) => {
      assert.equal(input.headers['chatgpt-account-id'], 'secret-id');
      if (!url.endsWith('/rate-limit-reset-credits')) return undefined;
      return new Response(JSON.stringify({ available_count: '2', credits: [
        { status: 'available', expires_at: '2027-01-01T00:00:00Z', title: 'server-secret' },
        { status: 'used', expires_at: '2026-01-01T00:00:00Z' },
        { status: 'available', expires_at: 'invalid' },
      ], token: 'server-secret' }));
    } });
    f.write('auth.json', { [provider]: f.credential });
    const before = fs.readFileSync(path.join(f.dir, 'auth.json'), 'utf8');
    const result = await f.manager.accountStatus({ provider });
    assert.deepEqual(result.accounts[0].resetCredits, {
      availableCount: 2, credits: [{ expiresAt: Date.parse('2027-01-01T00:00:00Z') / 1000 }, {}],
    });
    assert.equal(result.accounts[0].primary.remainingPercent, 75);
    assert.equal(result.accounts[0].error, undefined);
    assert.doesNotMatch(JSON.stringify(result), /secret|Bearer/);
    assert.equal(fs.readFileSync(path.join(f.dir, 'auth.json'), 'utf8'), before);
  }
});
test('optional reset credit failures never hide valid usage', async t => {
  for (const response of [
    () => new Response('server-secret', { status: 403 }),
    () => new Response('invalid JSON'),
    () => new Response('a'.repeat(256 * 1024 + 1)),
    () => new Response(JSON.stringify({ available_count: -1 })),
    () => new Response(JSON.stringify({ available_count: null })),
    () => { throw new Error('secret-network-error'); },
  ]) {
    const f = fixture(t, { response: url => url.endsWith('/rate-limit-reset-credits') ? response() : undefined });
    const result = await f.manager.accountStatus({ provider: 'openai' });
    assert.equal(result.accounts[0].primary.remainingPercent, 75);
    assert.equal(result.accounts[0].resetCredits, undefined);
    assert.equal(result.accounts[0].error, undefined);
    assert.doesNotMatch(JSON.stringify(result), /secret/);
  }
});
test('zero banked resets are represented without inventing credits', async t => {
  const f = fixture(t, { response: url => url.endsWith('/rate-limit-reset-credits')
    ? new Response('{"available_count":0}') : undefined });
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.deepEqual(result.accounts[0].resetCredits, { availableCount: 0, credits: [] });
});
test('rotated tokens with the same account ID merge into the managed alias', async t => {
  const f = fixture(t);
  f.write('openai-chatgpt-accounts.json', { version: 1, accounts: {
    X: { ...f.credential, access: 'older-access', expires: 1 },
    Y: { ...f.credential, accountId: 'other-id' },
  } });
  const before = fs.readFileSync(path.join(f.dir, 'openai-chatgpt-accounts.json'), 'utf8');
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.deepEqual(result.accounts.map(r => r.name), ['X', 'Y']);
  assert.equal(result.accounts[0].primary.remainingPercent, 75);
  assert.equal(result.defaultAccount, undefined); assert.equal(result.activeAccount, undefined);
  assert.equal(f.calls(), 4);
  assert.equal(fs.readFileSync(path.join(f.dir, 'openai-chatgpt-accounts.json'), 'utf8'), before);
});
test('JWT account identity also merges rotated native credentials', async t => {
  const f = fixture(t);
  const access = `header.${Buffer.from(JSON.stringify({ 'https://api.openai.com/auth': { chatgpt_account_id: 'secret-id' } })).toString('base64url')}.signature`;
  f.write('openai-chatgpt-accounts.json', { version: 1, accounts: { X: { ...f.credential, accountId: undefined, access, expires: 1 } } });
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.deepEqual(result.accounts.map(r => r.name), ['X']); assert.equal(f.calls(), 2);
});
test('unknown or different IDs are not merged merely because quota matches', async t => {
  const f = fixture(t);
  f.write('openai-chatgpt-accounts.json', { version: 1, accounts: { X: { ...f.credential, accountId: 'different-id' } } });
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.deepEqual(result.accounts.map(r => r.name), ['Pi 已保存授权', 'X']);
  assert.equal(result.defaultAccount, undefined);
});
test('native duplicates preserve managed visibility and provider isolation', async t => {
  const f = fixture(t);
  f.write('openai-chatgpt-accounts.json', { version: 1, accounts: { X: { ...f.credential, access: 'rotated' } } });
  f.write('openai-chatgpt-account-usage.json', { hiddenAccounts: ['X'] });
  f.write('codex-accounts.json', { version: 1, accounts: { Legacy: f.credential } });
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.deepEqual(result.accounts.map(r => r.name), ['X']); assert.equal(result.accounts[0].hidden, true); assert.equal(f.calls(), 0);
});
test('TTL, force and concurrent refresh coalescing', async t => {
  const f = fixture(t);
  await Promise.all([f.manager.accountStatus({ provider: 'openai', force: true }), f.manager.accountStatus({ provider: 'openai', force: true })]);
  assert.equal(f.calls(), 2);
  assert.equal((await f.manager.accountStatus({ provider: 'openai' })).cached, true);
  await f.manager.accountStatus({ provider: 'openai', force: true }); assert.equal(f.calls(), 4);
  f.advance(); await f.manager.accountStatus({ provider: 'openai' }); assert.equal(f.calls(), 6);
});
test('provider isolation and API key do not fall back to another OAuth provider', async t => {
  const f = fixture(t);
  f.write('auth.json', { openai: { type: 'api_key', key: 'private-key' }, 'openai-codex': f.credential });
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.deepEqual(result.accounts, []); assert.equal(f.calls(), 0);
  assert.equal((await f.manager.accountStatus({ provider: 'openai-codex' })).accounts.length, 1);
});
test('expired credentials produce explicit errors without refresh or network', async t => {
  const f = fixture(t); f.write('auth.json', { openai: { ...f.credential, expires: 1 } });
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.match(result.accounts[0].error, /过期/); assert.equal(f.calls(), 0);
});
test('hidden managed accounts do not trigger quota requests', async t => {
  const f = fixture(t); f.write('auth.json', {});
  f.write('openai-chatgpt-accounts.json', { version: 1, accounts: { work: f.credential } });
  f.write('openai-chatgpt-account-usage.json', { hiddenAccounts: ['work'] });
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.equal(result.accounts[0].hidden, true); assert.equal(f.calls(), 0);
});
test('HTTP errors and invalid response shapes never expose provider body', async t => {
  for (const response of [() => new Response('secret-response', { status: 401 }), () => new Response('{"secret":"private"}')]) {
    const f = fixture(t, { response }); const result = await f.manager.accountStatus({ provider: 'openai' });
    assert.match(result.accounts[0].error, /查询失败/); assert.doesNotMatch(JSON.stringify(result), /secret|private/);
  }
});
test('oversized responses are rejected', async t => {
  const f = fixture(t, { response: () => new Response('a'.repeat(256 * 1024 + 1)) });
  assert.match((await f.manager.accountStatus({ provider: 'openai' })).accounts[0].error, /查询失败/);
});
test('unsafe permissions, symlinks and malformed files fail closed', async t => {
  const f = fixture(t); const file = path.join(f.dir, 'auth.json');
  fs.chmodSync(file, 0o644); await assert.rejects(f.manager.accountStatus({ provider: 'openai' }), /权限/);
  fs.chmodSync(file, 0o600); fs.writeFileSync(file, '{'); await assert.rejects(f.manager.accountStatus({ provider: 'openai' }), /格式/);
  fs.renameSync(file, file + '.real'); fs.symlinkSync(file + '.real', file);
  await assert.rejects(f.manager.accountStatus({ provider: 'openai' }), /读取/); assert.equal(f.calls(), 0);
});
test('Antigravity quotas are read-only, deduplicated and cached', async t => {
  const f = fixture(t, { response: (url, input) => {
    if (url.endsWith(':retrieveUserQuotaSummary')) return new Response('SUBSCRIPTION_REQUIRED', { status: 403 });
    assert.match(url, /^https:\/\/(?:daily-cloudcode-pa\.sandbox|cloudcode-pa)\.googleapis\.com\/v1internal:fetchAvailableModels$/);
    assert.equal(input.method, 'POST');
    assert.deepEqual(JSON.parse(input.body), { project: 'project-id' });
    return new Response(JSON.stringify({ models: {
      'gemini-pro': { quotaInfo: { remainingFraction: 0.75, resetTime: '2026-10-04T00:00:00Z' } },
      'gemini-pro-thinking': { quotaInfo: { remainingFraction: 0.75, resetTime: '2026-10-04T00:00:00Z' } },
      'claude': { quotaInfo: { remainingFraction: 0.5 } },
    }, secret: 'server-secret' }));
  } });
  f.write('auth.json', { antigravity: { ...f.credential, projectId: 'project-id' } });
  const before = fs.readFileSync(path.join(f.dir, 'auth.json'), 'utf8');
  const result = await f.manager.accountStatus({ provider: 'antigravity' });
  assert.equal(result.gemini.kind, 'loaded'); assert.equal(result.gemini.isActive, true);
  assert.deepEqual(result.gemini.quotas, [{ remainingPercent: 75, resetAt: Date.parse('2026-10-04T00:00:00Z') }]);
  assert.deepEqual(result.accounts, []); assert.equal(result.supportsAccountSwitch, false);
  assert.doesNotMatch(JSON.stringify(result), /secret|project-id/);
  assert.equal(fs.readFileSync(path.join(f.dir, 'auth.json'), 'utf8'), before);
  assert.equal(result.gemini.capturedAt, 100000);
  f.advance();
  const refreshed = await f.manager.accountStatus({ provider: 'antigravity' });
  assert.equal(refreshed.gemini.capturedAt, 160001);
  const cached = await f.manager.accountStatus({ provider: 'antigravity' });
  assert.equal(cached.cached, true);
  assert.equal(cached.gemini.capturedAt, refreshed.gemini.capturedAt);
  assert.equal(f.calls(), 6);
});
test('Antigravity summary preserves weekly reset time and window identity', async t => {
  const resetTime = '2026-10-11T00:00:00Z';
  const f = fixture(t, { response: (url, input) => {
    assert.ok(url.endsWith(':retrieveUserQuotaSummary'));
    assert.deepEqual(JSON.parse(input.body), {});
    return new Response(JSON.stringify({ groups: [
      { displayName: 'Gemini', buckets: [
        { window: 'weekly', displayName: 'Weekly Limit Remaining', remainingFraction: 0.75, resetTime },
        { window: '5h', displayName: 'Five Hour Limit Remaining', remainingFraction: 0.75, resetTime },
      ] },
      { displayName: 'Claude', buckets: [{ remainingFraction: 0.1, resetTime }] },
    ], secret: 'server-secret' }));
  } });
  f.write('auth.json', { antigravity: f.credential });
  const result = await f.manager.accountStatus({ provider: 'antigravity' });
  assert.equal(result.gemini.kind, 'loaded');
  assert.equal(result.gemini.capturedAt, 100000);
  assert.deepEqual(result.gemini.quotas, [
    { remainingPercent: 75, resetAt: Date.parse(resetTime), window: '5h Five Hour Limit Remaining' },
    { remainingPercent: 75, resetAt: Date.parse(resetTime), window: 'weekly Weekly Limit Remaining' },
  ]);
  assert.equal(f.calls(), 1);
  assert.doesNotMatch(JSON.stringify(result), /secret/);
});
test('Antigravity malformed summary falls back to model quotas', async t => {
  const f = fixture(t, { response: url => new Response(JSON.stringify(
    url.endsWith(':retrieveUserQuotaSummary')
      ? { groups: [{ displayName: 'Gemini', buckets: [{ remainingFraction: 'invalid' }] }] }
      : { models: { gemini: { quotaInfo: { remainingFraction: 0.5, resetTime: 'invalid' } } } }
  )) });
  f.write('auth.json', { antigravity: f.credential });
  const result = await f.manager.accountStatus({ provider: 'antigravity' });
  assert.deepEqual(result.gemini.quotas, [{ remainingPercent: 50 }]);
  assert.equal(f.calls(), 2);
});
test('Antigravity missing and expired OAuth are explicit and never use other providers', async t => {
  const f = fixture(t);
  assert.equal((await f.manager.accountStatus({ provider: 'antigravity' })).gemini.kind, 'unconfigured');
  f.write('auth.json', { antigravity: { ...f.credential, expires: 1 } });
  const result = await f.manager.accountStatus({ provider: 'antigravity', force: true });
  assert.match(result.gemini.error, /过期/); assert.equal(f.calls(), 0);
});
test('Antigravity failures redact bodies and malformed quotas', async t => {
  const f = fixture(t, { response: () => new Response('{"secret":"private"}') });
  f.write('auth.json', { antigravity: f.credential });
  const result = await f.manager.accountStatus({ provider: 'antigravity' });
  assert.equal(result.gemini.kind, 'failed'); assert.match(result.gemini.error, /查询失败/);
  assert.doesNotMatch(JSON.stringify(result), /secret|private/);
});
test('OpenAI quota cards also include configured Antigravity usage', async t => {
  const f = fixture(t, { response: url => url.includes('googleapis.com')
    ? new Response(JSON.stringify({ models: { gemini: { quotaInfo: { remainingFraction: 0.5 } } } })) : undefined });
  f.write('auth.json', { openai: f.credential, antigravity: f.credential });
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.equal(result.accounts[0].primary.remainingPercent, 75);
  assert.equal(result.gemini.quotas[0].remainingPercent, 50); assert.equal(result.gemini.isActive, false);
});
test('quota HTTP failures do not await a hanging response cleanup', { timeout: 2000 }, async t => {
  const f = fixture(t, { response: () => new Response(new ReadableStream({
    cancel() { return new Promise(() => {}); },
  }), { status: 503 }) });
  f.write('auth.json', { openai: f.credential, antigravity: f.credential });
  const result = await f.manager.accountStatus({ provider: 'openai' });
  assert.match(result.accounts[0].error, /额度查询失败/);
  assert.equal(result.gemini.kind, 'failed');
  assert.equal(result.gemini.capturedAt, undefined);
});

test('unsupported providers and closed managers reject without network', async t => {
  const f = fixture(t); await assert.rejects(f.manager.accountStatus({ provider: 'unsupported' }));
  f.manager.close(); await assert.rejects(f.manager.accountStatus({ provider: 'openai' })); assert.equal(f.calls(), 0);
});
