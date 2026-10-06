// Secondary telemetry only; never controls provider lifecycle or orchestration.
const states = new WeakMap();
const count = value => Number.isSafeInteger(value) && value >= 0 ? value : undefined;
export function startPiMessage(turn, now = Date.now()) {
  const state = states.get(turn) ?? { input: 0, output: 0, cached: 0, creation: 0, duration: 0, cost: 0, messages: 0, complete: true, costKnown: true, speedTokens: 0, speedDuration: 0 };
  state.started = now;
  state.chunks = [];
  state.overflow = false;
  states.set(turn, state);
}
export function recordPiDelta(turn, delta, now = Date.now()) {
  const state = states.get(turn);
  if (!state || state.started === undefined || state.overflow) return;
  if (!['text_delta', 'thinking_delta', 'toolcall_delta'].includes(delta?.type) || typeof delta.delta !== 'string' || !delta.delta.length) return;
  // Bound memory even for huge responses. Missing samples never become a speed.
  if (state.chunks.length >= 8192) { state.overflow = true; return; }
  state.chunks.push({ time: now, weight: Array.from(delta.delta).length, type: delta.type });
}
function sampleSpeed(state, message, output) {
  if (state.overflow || output === undefined || output < 32 || message?.stopReason === 'error' || message?.stopReason === 'aborted') return;
  const reasoning = count(message?.usage?.reasoning);
  // Responses APIs expose reasoning summaries, not the full reasoning stream.
  const summary = /responses/.test(message?.api ?? '');
  const thinkingVisible = !summary && state.chunks.some(c => c.type === 'thinking_delta');
  const hidden = (reasoning ?? 0) > 0 && !thinkingVisible;
  // Without the reasoning count, a summary stream cannot be calibrated safely.
  if (summary && reasoning === undefined) return;
  const chunks = state.chunks.filter(c => !summary || c.type !== 'thinking_delta');
  const hasTools = message?.content?.some(c => c.type === 'toolCall');
  if (hasTools && !chunks.some(c => c.type === 'toolcall_delta')) return;
  if (chunks.length < 5) return;
  const tokens = output - (hidden ? reasoning : 0);
  if (tokens < 32) return;
  const totalWeight = chunks.reduce((sum, c) => sum + c.weight, 0);
  // Pi lacks per-chunk token counts. Calibrate chunk character weights against
  // actual output usage; estimate only the boundary chunk's token share. For
  // hidden reasoning use the final ~80% of visible output, as AA does.
  let start = 0, excludedWeight = chunks[0].weight;
  if (hidden) {
    const cutoff = totalWeight * 0.2;
    while (start < chunks.length - 1 && excludedWeight < cutoff) excludedWeight += chunks[++start].weight;
  }
  const elapsed = chunks.at(-1).time - chunks[start].time;
  const measuredTokens = tokens * (1 - excludedWeight / totalWeight);
  // Short/buffered streams are unstable and can produce absurd throughput.
  if (chunks.length - start < 4 || elapsed < 500 || measuredTokens < 16) return;
  state.speedTokens += measuredTokens;
  state.speedDuration += elapsed;
}
export function endPiMessage(turn, message, now = Date.now()) {
  const state = states.get(turn);
  if (!state || state.started === undefined) return;
  const usage = message?.usage;
  const input = count(usage?.input), output = count(usage?.output);
  const cached = count(usage?.cacheRead), creation = count(usage?.cacheWrite);
  state.complete &&= input !== undefined && output !== undefined && cached !== undefined && creation !== undefined;
  state.input += (input ?? 0) + (cached ?? 0) + (creation ?? 0);
  state.output += output ?? 0;
  state.cached += cached ?? 0;
  state.creation += creation ?? 0;
  state.duration += Math.max(0, now - state.started);
  sampleSpeed(state, message, output);
  const cost = usage?.cost?.total;
  state.costKnown &&= Number.isFinite(cost) && cost >= 0;
  state.cost += Number.isFinite(cost) && cost >= 0 ? cost : 0;
  state.messages++;
  delete state.started;
  delete state.chunks;
}
export function piTurnMetrics(turn) {
  const state = states.get(turn);
  if (!state?.messages || !state.complete || state.started !== undefined) return {};
  return {
    turnTokenUsage: { usageScope: 'main_agent', usageStatus: 'complete', hasSubagents: false,
      inputTokens: state.input, outputTokens: state.output,
      cachedInputTokens: state.cached, cacheCreationTokens: state.creation },
    telemetry: { outputDurationMs: state.duration, speedMethod: 'aa-approx-v1',
      ...(state.speedDuration > 0 ? { speedTokens: state.speedTokens, speedDurationMs: state.speedDuration } : {}),
      ...(state.costKnown ? { totalCostUsd: state.cost } : {}) },
  };
}
