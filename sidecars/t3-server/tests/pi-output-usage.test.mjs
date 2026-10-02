import { test } from 'node:test';
import assert from 'node:assert/strict';
import { observePiOutputUsage as observe, piOutputUsage as snapshot } from '../pi-output-usage.mjs';
const start = { type: 'message_start', message: { role: 'assistant' } };
const end = output => ({ type: 'message_end', message: { role: 'assistant', usage: { output } } });

test('actual response usage and request time exclude tools, reasoning is not counted twice', () => {
  const turn = {};
  observe(turn, start, 0);
  observe(turn, end(100), 2000);
  assert.equal(snapshot(turn, 30000).turnTokenUsage.assistantDurationMs, 2000);
  observe(turn, start, 30000);
  observe(turn, { type: 'message_update', assistantMessageEvent: { partial: { usage: { output: 40, reasoning: 30 } } } }, 31000);
  assert.equal(snapshot(turn, 31000).turnTokenUsage.outputTokens, 140);
  assert.equal(snapshot(turn, 31000).turnTokenUsage.assistantDurationMs, 3000);
  observe(turn, end(50), 32000);
  assert.equal(snapshot(turn, 60000).turnTokenUsage.outputTokens, 150);
  assert.equal(snapshot(turn, 60000).turnTokenUsage.assistantDurationMs, 4000);
  assert.deepEqual(snapshot({}), {});
});

test('missing usage and user/tool events do not invent or dilute throughput', () => {
  const turn = {};
  observe(turn, start, 0);
  observe(turn, { type: 'message_end', message: { role: 'toolResult', usage: { output: 500 } } }, 100);
  observe(turn, end(20), 1000);
  observe(turn, start, 2000);
  observe(turn, { type: 'message_end', message: { role: 'assistant' } }, 12000);
  assert.equal(snapshot(turn).turnTokenUsage.outputTokens, 20);
  assert.equal(snapshot(turn).turnTokenUsage.assistantDurationMs, 1000);
});
