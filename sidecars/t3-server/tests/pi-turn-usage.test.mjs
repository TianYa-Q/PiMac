import test from 'node:test';
import assert from 'node:assert/strict';
import { startPiMessage, recordPiDelta, endPiMessage, piTurnMetrics } from '../pi-turn-usage.mjs';
const message = { usage: { input: 100, output: 50, cacheRead: 200, cacheWrite: 10, cost: { total: 0.02 } } };
test('turn totals exclude tool time and do not include earlier sessions', () => {
  const turn = {};
  startPiMessage(turn, 1000); endPiMessage(turn, message, 2000);
  startPiMessage(turn, 12000); endPiMessage(turn, message, 14000);
  endPiMessage(turn, message, 15000); // duplicate is ignored
  assert.deepEqual(piTurnMetrics(turn), {
    turnTokenUsage: { usageScope: 'main_agent', usageStatus: 'complete', hasSubagents: false,
      inputTokens: 620, outputTokens: 100, cachedInputTokens: 400, cacheCreationTokens: 20 },
    telemetry: { outputDurationMs: 3000, speedMethod: 'aa-approx-v1', totalCostUsd: 0.04 },
  });
  assert.deepEqual(piTurnMetrics({}), {});
});
test('missing usage or unfinished response never manufactures speed or cost', () => {
  const turn = {};
  startPiMessage(turn, 1000); endPiMessage(turn, {}, 2000);
  assert.deepEqual(piTurnMetrics(turn), {});
  const pending = {};
  startPiMessage(pending, 1000); endPiMessage(pending, message, 2000);
  startPiMessage(pending, 3000);
  assert.deepEqual(piTurnMetrics(pending), {});
});
function streamed(turn, chunks, start = 10000, interval = 100, type = 'text_delta') {
  for (let i = 0; i < chunks; i++) recordPiDelta(turn, { type, delta: '0123456789' }, start + i * interval);
}
test('AA calibration excludes prefill, first chunk, usage trailer and tools', () => {
  const turn = {};
  startPiMessage(turn, 0);
  streamed(turn, 10);
  endPiMessage(turn, { ...message, usage: { ...message.usage, output: 100 } }, 30000);
  const metrics = piTurnMetrics(turn).telemetry;
  assert.equal(metrics.speedTokens, 90);
  assert.equal(metrics.speedDurationMs, 900);
  startPiMessage(turn, 100000); // tool execution gap must not enter speed
  streamed(turn, 10, 120000, 200);
  endPiMessage(turn, { ...message, usage: { ...message.usage, output: 100 } }, 130000);
  assert.equal(piTurnMetrics(turn).telemetry.speedTokens, 180);
  assert.equal(piTurnMetrics(turn).telemetry.speedDurationMs, 2700);
});
test('Pi Codex Responses: ignore reasoning summaries and hidden reasoning usage, measure answer tail', () => {
  const turn = {};
  startPiMessage(turn, 0);
  streamed(turn, 5, 1000, 1000, 'thinking_delta');
  streamed(turn, 10, 20000, 100);
  endPiMessage(turn, { api: 'openai-codex-responses', content: [{ type: 'text', text: 'answer' }],
    usage: { ...message.usage, output: 600, reasoning: 500 } }, 30000);
  const metrics = piTurnMetrics(turn).telemetry;
  assert.equal(metrics.speedTokens, 80); // not 480: reasoning is not visible output
  assert.equal(metrics.speedDurationMs, 800);
  assert.equal(metrics.speedTokens * 1000 / metrics.speedDurationMs, 100);
  assert.equal(piTurnMetrics(turn).turnTokenUsage.outputTokens, 600); // billing stays intact
});
test('full thinking streams are measured, reasoning tokens are not double-counted', () => {
  const turn = {};
  startPiMessage(turn, 0);
  streamed(turn, 5, 1000, 100, 'thinking_delta');
  streamed(turn, 5, 1500, 100);
  endPiMessage(turn, { api: 'anthropic-messages',
    usage: { ...message.usage, output: 100, reasoning: 50 } }, 3000);
  assert.equal(piTurnMetrics(turn).telemetry.speedTokens, 90);
  assert.equal(piTurnMetrics(turn).telemetry.speedDurationMs, 900);
});
test('buffered, short and uncalibratable Codex streams have no speed', () => {
  for (const mode of ['short', 'buffered', 'unknown-reasoning']) {
    const turn = {};
    startPiMessage(turn, 0);
    streamed(turn, mode === 'short' ? 1 : 10, 1000, mode === 'buffered' ? 0 : 100);
    endPiMessage(turn, { api: 'openai-codex-responses',
      usage: { ...message.usage, output: 100, ...(mode === 'unknown-reasoning' ? {} : { reasoning: 0 }) } }, 5000);
    assert.equal(piTurnMetrics(turn).telemetry.speedTokens, undefined);
  }
});

test('zero cost is valid but absent cost remains absent', () => {
  const turn = {};
  startPiMessage(turn, 0); endPiMessage(turn, { usage: { ...message.usage, cost: undefined } }, 1000);
  assert.equal(piTurnMetrics(turn).telemetry.totalCostUsd, undefined);
});
