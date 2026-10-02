import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, writeFileSync, statSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { configureAccountStatuses, recordAccountStatus, accountStatus, clearAccountStatuses } from '../account-status.mjs';

const event = payload => ({ type: 'extension_ui_request', method: 'setStatus', statusKey: 'account-usage-gui', statusText: JSON.stringify(payload) });
const snapshot = { version: 2, provider: 'openai', updatedAt: 1700000000000, defaultAccount: 'first',
  activeAccount: 'first', managesSelectedAuth: true, accounts: [{ name: 'first', primary: { remainingPercent: 75, resetAt: 1700000001 },
    credential: { accessToken: 'must-not-persist' } }], accessToken: 'must-not-persist' };

test('restart immediately restores provider-isolated quotas without restoring task auth', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pimac-quota-cache-'));
  try {
    configureAccountStatuses(directory);
    recordAccountStatus('thread-before-restart', event(snapshot));
    const file = join(directory, 'account-quota-cache.json');
    const text = readFileSync(file, 'utf8');
    assert.equal(text.includes('must-not-persist'), false);
    assert.equal(text.includes('activeAccount'), false);
    assert.equal(statSync(file).mode & 0o777, 0o600);
    configureAccountStatuses(directory); // No new extension status or network call.
    const cached = accountStatus('new-thread', 'openai');
    assert.equal(cached.accounts[0].primary.remainingPercent, 75);
    assert.equal(cached.updatedAt, snapshot.updatedAt); // Not falsely stamped as fresh.
    assert.equal(cached.activeAccount, undefined);
    assert.equal(cached.managesSelectedAuth, false);
    assert.equal(accountStatus('new-thread', 'openai-codex'), null);
    recordAccountStatus('@discovery', event({ ...snapshot, updatedAt: snapshot.updatedAt + 1000,
      accounts: [{ name: 'first', primary: { remainingPercent: 70 } }] }));
    assert.equal(accountStatus('new-thread', 'openai').accounts[0].primary.remainingPercent, 70);
  } finally { clearAccountStatuses(); rmSync(directory, { recursive: true, force: true }); }
});

test('corrupt startup cache cannot block fresh quota reporting', () => {
  const directory = mkdtempSync(join(tmpdir(), 'pimac-quota-corrupt-'));
  try {
    writeFileSync(join(directory, 'account-quota-cache.json'), '{broken', { mode: 0o600 });
    configureAccountStatuses(directory);
    assert.equal(accountStatus('new-thread', 'openai'), null);
    recordAccountStatus('@discovery', event(snapshot));
    assert.equal(accountStatus('new-thread', 'openai').accounts[0].name, 'first');
  } finally { clearAccountStatuses(); rmSync(directory, { recursive: true, force: true }); }
});
