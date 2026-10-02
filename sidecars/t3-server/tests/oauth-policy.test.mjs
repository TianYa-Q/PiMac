import { test } from 'node:test';
import assert from 'node:assert/strict';
import { loopbackOAuthCallbackAllowed } from '../oauth-policy.mjs';

test('OAuth callback is allowed only on the dedicated loopback listener', () => {
  const socket = { localAddress: '127.0.0.1', localPort: 34338, remoteAddress: '127.0.0.1' };
  const request = { method: 'GET', url: '/callback?state=fixture&code=fixture', headers: {}, source: { socket } };
  assert.equal(loopbackOAuthCallbackAllowed(request), true);
  for (const change of [
    { method: 'POST' }, { url: '/callback/extra' }, { headers: { origin: 'https://attacker.invalid' } },
    { source: undefined },
    ...[{ localPort: 12345 }, { localAddress: '0.0.0.0' }, { remoteAddress: '192.0.2.1' }]
      .map(change => ({ source: { socket: { ...socket, ...change } } })),
  ]) assert.equal(loopbackOAuthCallbackAllowed({ ...request, ...change }), false);
});
