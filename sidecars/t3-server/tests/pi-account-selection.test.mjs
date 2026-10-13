import test from 'node:test';
import assert from 'node:assert/strict';
import { createPiAccountSelections } from '../pi-account-selection.mjs';
const event = (activeAccount, updatedAt, extra = {}) => ({ method: 'setStatus', statusKey: 'account-usage-gui',
  statusText: JSON.stringify({ version: 2, provider: 'openai', accounts: [], activeAccount, updatedAt,
    managesSelectedAuth: true, supportsAccountSwitch: true, ...extra }) });
test('rotation updates only its own thread; quota/default and invalid events never infer a binding', () => {
  const store = createPiAccountSelections();
  store.record('first', event('X', 1000));
  store.record('second', event('X', 3000));
  store.record('first', event('Y', 2000));
  assert.equal(store.read('first', 'openai').activeAccount, 'Y');
  assert.equal(store.read('second', 'openai').activeAccount, 'X');
  assert.equal(store.read('first', 'openai-codex'), undefined);
  store.record('first', event('X', 1000));
  store.record('first', event('X', -1));
  store.record('first', { method: 'setStatus', statusKey: 'account-usage-gui', statusText: '{' });
  assert.equal(store.read('first', 'openai').activeAccount, 'Y');
  assert.equal(JSON.stringify(store.read('first', 'openai')).includes('accounts'), false);
  store.record('first', event(undefined, 4000, { managesSelectedAuth: false, defaultAccount: 'X' }));
  assert.equal(store.read('first', 'openai').activeAccount, undefined);
  store.record('first', { method: 'setStatus', statusKey: 'account-usage-gui', statusText: '' });
  assert.equal(store.read('first', 'openai'), undefined);
  store.close();
  assert.equal(store.read('second', 'openai'), undefined);
});
