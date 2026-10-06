import test from 'node:test';
import assert from 'node:assert/strict';
import { startPiMessage, endPiMessage, piTurnMetrics } from '../pi-turn-usage.mjs';
const message = { usage: { input: 100, output: 50, cacheRead: 200, cacheWrite: 10, cost: { total: 0.02 } } };
test('turn totals exclude tool time and do not include earlier sessions', () => {
  const turn = {};
  startPiMessage(turn, 1000); endPiMessage(turn, message, 2000);
  startPiMessage(turn, 12000); endPiMessage(turn, message, 14000);
  endPiMessage(turn, message, 15000); // duplicate is ignored
  assert.deepEqual(piTurnMetrics(turn), {
    turnTokenUsage: { usageScope: 'main_agent', usageStatus: 'complete', hasSubagents: false,
      inputTokens: 620, outputTokens: 100, cachedInputTokens: 400, cacheCreationTokens: 20 },
    telemetry: { outputDurationMs: 3000, totalCostUsd: 0.04 },
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
test('zero cost is valid but absent cost remains absent', () => {
  const turn = {};
  startPiMessage(turn, 0); endPiMessage(turn, { usage: { ...message.usage, cost: undefined } }, 1000);
  assert.equal(piTurnMetrics(turn).telemetry.totalCostUsd, undefined);
});
