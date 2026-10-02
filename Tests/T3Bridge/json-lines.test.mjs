import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createJSONLineReceiver } from '../../Sources/PiMacApp/Resources/t3-bridge/json-lines.mjs';

const message = { id: 'native', result: { title: 'before\u2028middle\u2029after', text: '你好🙂\nnext\rline' } };
const wire = Buffer.from(`${JSON.stringify(message)}\n`);

test('Foundation Unicode separators inside JSON are not IPC record boundaries', () => {
  const values = [];
  const receive = createJSONLineReceiver(value => values.push(value), {
    onInvalid: () => assert.fail('valid JSON was split'),
  });
  receive(wire);
  assert.deepEqual(values, [message]);
});

test('LF framing preserves split UTF-8 and multiple records across every byte boundary', () => {
  for (let split = 0; split <= wire.length; split++) {
    const values = [];
    const receive = createJSONLineReceiver(value => values.push(value));
    receive(wire.subarray(0, split));
    receive(wire.subarray(split));
    receive(Buffer.concat([Buffer.from('\r\n\n'), wire, wire]));
    assert.deepEqual(values, [message, message, message]);
  }
  const values = [];
  const receive = createJSONLineReceiver(value => values.push(value));
  for (const byte of wire) receive(Buffer.from([byte]));
  assert.deepEqual(values, [message]);
});

test('malformed and oversized records are discarded up to LF without poisoning the next reply', () => {
  const values = [];
  let invalid = 0;
  const receive = createJSONLineReceiver(value => values.push(value), {
    onInvalid: () => invalid++, maxBytes: 64,
  });
  receive(Buffer.from('{broken}\n'));
  receive(Buffer.from('x'.repeat(40)));
  receive(Buffer.from('x'.repeat(40)));
  receive(Buffer.from('\n{"id":"next"}\r\n'));
  assert.equal(invalid, 2);
  assert.deepEqual(values, [{ id: 'next' }]);
});

test('large multi-read replies preserve content without rescanning earlier chunks', () => {
  const reply = { result: 'x'.repeat(1024 * 1024) + '\u2028\u2029' };
  const data = Buffer.from(`${JSON.stringify(reply)}\n`);
  const values = [];
  const receive = createJSONLineReceiver(value => values.push(value));
  for (let offset = 0; offset < data.length; offset += 16384) receive(data.subarray(offset, offset + 16384));
  assert.deepEqual(values, [reply]);
});
