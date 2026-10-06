// Secondary telemetry only; never controls provider lifecycle or orchestration.
const states = new WeakMap();
const count = value => Number.isSafeInteger(value) && value >= 0 ? value : undefined;
export function startPiMessage(turn, now = Date.now()) {
  const state = states.get(turn) ?? { input: 0, output: 0, cached: 0, creation: 0, duration: 0, cost: 0, messages: 0, complete: true, costKnown: true };
  state.started = now;
  states.set(turn, state);
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
  const cost = usage?.cost?.total;
  state.costKnown &&= Number.isFinite(cost) && cost >= 0;
  state.cost += Number.isFinite(cost) && cost >= 0 ? cost : 0;
  state.messages++;
  delete state.started;
}
export function piTurnMetrics(turn) {
  const state = states.get(turn);
  if (!state?.messages || !state.complete || state.started !== undefined) return {};
  return {
    turnTokenUsage: { usageScope: 'main_agent', usageStatus: 'complete', hasSubagents: false,
      inputTokens: state.input, outputTokens: state.output,
      cachedInputTokens: state.cached, cacheCreationTokens: state.creation },
    telemetry: { outputDurationMs: state.duration,
      ...(state.costKnown ? { totalCostUsd: state.cost } : {}) },
  };
}
