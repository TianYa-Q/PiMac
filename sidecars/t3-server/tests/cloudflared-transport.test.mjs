import assert from 'node:assert/strict';
import { test } from 'node:test';
import { cloudflaredEnvironment } from '../cloudflared-transport.mjs';

test('new connectors default to TCP without changing the Server/provider environment', () => {
  const environment = { HOME: '/private/home', HTTPS_PROXY: 'http://localhost:7890', TUNNEL_TOKEN: 'stale' };
  const child = cloudflaredEnvironment(environment, 'current');
  assert.equal(child.TUNNEL_TRANSPORT_PROTOCOL, 'http2');
  assert.equal(child.TUNNEL_TOKEN, 'current');
  assert.equal(child.HTTPS_PROXY, environment.HTTPS_PROXY);
  assert.equal(environment.TUNNEL_TOKEN, 'stale');
  assert.equal(environment.TUNNEL_TRANSPORT_PROTOCOL, undefined);
});

test('inherited protocol cannot switch the connector back to UDP', () => {
  for (const protocol of ['auto', 'quic', 'http2', '']) {
    const environment = { TUNNEL_TRANSPORT_PROTOCOL: protocol };
    assert.equal(cloudflaredEnvironment(environment, 'token').TUNNEL_TRANSPORT_PROTOCOL, 'http2');
    assert.equal(environment.TUNNEL_TRANSPORT_PROTOCOL, protocol);
  }
});
