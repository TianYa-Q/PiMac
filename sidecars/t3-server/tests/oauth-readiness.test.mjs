import { test } from 'node:test';
import assert from 'node:assert/strict';
import * as Effect from 'effect/Effect';
import { HttpServerRequest } from 'effect/http';
import { oauthAwareCommandReadiness } from '../oauth-readiness.mjs';

const request = {
  method: 'GET', url: '/callback?state=invalid&code=invalid', headers: {},
  source: { socket: { localAddress: '127.0.0.1', localPort: 34338, remoteAddress: '127.0.0.1' } },
};
const run = (input, ready, handler) => Effect.runPromise(
  oauthAwareCommandReadiness(handler, ready).pipe(
    Effect.provideService(HttpServerRequest.HttpServerRequest, input)));

test('dedicated OAuth callback runs without resolving main server readiness', async () => {
  const result = await run(request, Effect.die('startup service unavailable'), Effect.succeed(400));
  assert.equal(result, 400);
});

test('ordinary requests still wait for startup before their handler', async () => {
  for (const input of [
    { ...request, url: '/api/connect/status' },
    { ...request, source: { socket: { ...request.source.socket, localPort: 12345 } } },
    { ...request, headers: { origin: 'https://attacker.invalid' } },
  ]) {
    const order = [];
    await run(input, Effect.sync(() => order.push('ready')), Effect.sync(() => order.push('handler')));
    assert.deepEqual(order, ['ready', 'handler']);
    await assert.rejects(run(input, Effect.die('not ready'), Effect.succeed(200)));
  }
});
