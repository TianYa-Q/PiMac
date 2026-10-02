import { test } from 'node:test';
import assert from 'node:assert/strict';
import { OutputSpeed } from '../output-speed.mjs';

test('output speed uses provider tokens, excludes tool time, and resets per turn', () => {
  const speed = new OutputSpeed();
  speed.consume({ type: 'message_start', message: { role: 'assistant' } }, 0);
  speed.consume({ type: 'message_update', assistantMessageEvent: { partial: { usage: { output: 10 } } } }, 1000);
  assert.equal(speed.value, 10);
  speed.consume({ type: 'message_end', message: { role: 'assistant', usage: { output: 20 } } }, 2000);
  speed.consume({ type: 'tool_execution_start' }, 3000);
  speed.consume({ type: 'message_start', message: { role: 'assistant' } }, 12000);
  speed.consume({ type: 'message_end', message: { role: 'assistant', usage: { output: 10 } } }, 13000);
  assert.equal(speed.value, 10);
  speed.reset();
  speed.consume({ type: 'message_start', message: { role: 'assistant' } }, 14000);
  speed.consume({ type: 'message_update', assistantMessageEvent: { delta: 'text without usage' } }, 15000);
  assert.equal(speed.value, null);
});
