import { test } from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createGateway } from '../../Sources/PiMacApp/Resources/t3-bridge/gateway.mjs';

const token = 'ab'.repeat(32);
async function fixture(t, send, timeoutMs) {
  const gateway = createGateway({ token, send, timeoutMs });
  gateway.server.listen(0, '127.0.0.1');
  await once(gateway.server, 'listening');
  t.after(() => gateway.close());
  const url = `http://127.0.0.1:${gateway.server.address().port}/internal/request`;
  const call = (body, headers = {}) => fetch(url, {
    method: 'POST', headers: { authorization: `Bearer ${token}`, ...headers },
    body: JSON.stringify(body),
  });
  return { gateway, url, call };
}

test('authentication rejects missing and wrong credentials without dispatch', async t => {
  let dispatched = false;
  const { call } = await fixture(t, () => { dispatched = true; });
  assert.equal((await call({ method: 'workspace.snapshot' }, { authorization: '' })).status, 401);
  assert.equal((await call({ method: 'workspace.snapshot' }, { authorization: `Bearer ${'cd'.repeat(32)}` })).status, 401);
  assert.equal(dispatched, false);
});

test('IPC correlation uses generated IDs and accepts only matching responses', async t => {
  let message;
  const { gateway, call } = await fixture(t, request => {
    message = request;
    gateway.receive({ id: 'unrelated', result: 'wrong' });
    gateway.receive({ id: request.id, result: { sessions: [] } });
  });
  const response = await call({ id: 'caller-id', method: 'workspace.snapshot' });
  assert.equal(response.status, 200);
  assert.notEqual(message.id, 'caller-id');
  assert.deepEqual((await response.json()).result, { sessions: [] });
});

test('unknown methods, browser origins and invalid field types never dispatch', async t => {
  let dispatched = false;
  const { call } = await fixture(t, () => { dispatched = true; });
  assert.equal((await call({ method: 'filesystem.write' })).status, 400);
  assert.equal((await call({ method: 'session.prompt', text: 12 })).status, 400);
  assert.equal((await call({ method: 'workspace.snapshot' }, { origin: 'https://evil.example' })).status, 403);
  assert.equal(dispatched, false);
});

test('timeout reports unknown outcome and does not retry mutations', async t => {
  let count = 0;
  const { call } = await fixture(t, () => { count++; }, 20);
  const response = await call({ method: 'session.prompt', target: 'session', text: 'hello' });
  assert.equal(response.status, 504);
  assert.equal((await response.json()).error, 'outcome_unknown');
  assert.equal(count, 1);
});

test('oversized input rejected and close fails pending requests', async t => {
  let gateway;
  const f = await fixture(t, request => {
    setImmediate(() => gateway.close());
  });
  gateway = f.gateway;
  assert.equal((await f.call({ method: 'session.prompt', text: 'x'.repeat(310 * 1024) })).status, 413);
  const response = await f.call({ method: 'workspace.snapshot' });
  assert.equal(response.status, 503);
});

test('token is mandatory and exact-length', () => {
  assert.throws(() => createGateway({ token: 'short', send() {} }));
});
