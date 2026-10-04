import test from 'node:test';
import assert from 'node:assert/strict';
import { boundedJSON, discardBody } from '../../../Sources/PiMacApp/Resources/t3-bridge/bounded-json.mjs';

const response = (source, headers) => new Response(new ReadableStream(source), { headers });
const bytes = value => new TextEncoder().encode(value);

test('tiny chunks and split UTF-8 are decoded within the actual byte budget', async () => {
  const raw = bytes(JSON.stringify({ text: '额度', padding: 'x'.repeat(20000) }));
  let index = 0;
  const body = response({ pull(controller) {
    if (index === raw.length) controller.close();
    else controller.enqueue(raw.subarray(index, ++index));
  } });
  assert.equal((await boundedJSON(body, { maxBytes: raw.length })).text, '额度');
  assert.equal(body.body.locked, false);
});

test('oversize advertised and chunked bodies return despite hanging cleanup', async () => {
  for (const headers of [undefined, { 'content-length': '9999' }]) {
    let cancelled = false;
    const body = response({ start(controller) { controller.enqueue(bytes('x'.repeat(100))); },
      cancel() { cancelled = true; return new Promise(() => {}); } }, headers);
    await assert.rejects(boundedJSON(body, { maxBytes: 20 }), /oversize/);
    assert.equal(cancelled, true);
    assert.equal(body.body.locked, false);
  }
});

test('abort closes a stalled read without awaiting source cleanup or losing reason', async () => {
  const controller = new AbortController();
  const body = response({ cancel() { return new Promise(() => {}); } });
  const reason = new Error('closed');
  const work = boundedJSON(body, { signal: controller.signal });
  controller.abort(reason);
  await assert.rejects(work, error => error === reason);
  assert.equal(body.body.locked, false);
});

test('malformed UTF-8, scalar and array JSON cannot cross IPC as records', async () => {
  for (const value of [bytes('null'), bytes('[]'), bytes('42'), bytes('{bad'), new Uint8Array([123, 34, 120, 34, 58, 34, 255, 34, 125])]) {
    await assert.rejects(boundedJSON(new Response(value)));
  }
});

test('discard observes cleanup rejection and does not wait for cleanup completion', async () => {
  for (const cancel of [() => new Promise(() => {}), () => Promise.reject(new Error('cleanup'))]) {
    discardBody(response({ cancel }));
  }
  await new Promise(setImmediate);
});
