// Request-local telemetry only; orchestration and persistence remain owned by T3.
const requests = new WeakMap();
const count = value => Number.isSafeInteger(value) && value >= 0 ? value : undefined;

export function observePiOutputUsage(turn, event, now = performance.now()) {
  let state = requests.get(turn);
  if (!state) {
    state = { output: 0, input: 0, duration: 0, current: null };
    requests.set(turn, state);
  }
  const message = event.message;
  if (event.type === 'message_start' && message?.role === 'assistant') {
    state.current = { started: now, output: undefined, input: 0 };
  } else if (event.type === 'message_update' ||
    (event.type === 'message_end' && message?.role === 'assistant')) {
    if (!state.current) return;
    const usage = event.usage ?? event.assistantMessageEvent?.partial?.usage ?? message?.usage;
    const output = count(usage?.output);
    if (output !== undefined) state.current.output = Math.max(state.current.output ?? 0, output);
    state.current.input = count(usage?.input) ?? state.current.input;
    if (event.type === 'message_end') {
      if (state.current.output > 0 && now > state.current.started) {
        state.output += state.current.output;
        state.input += state.current.input;
        state.duration += now - state.current.started;
      }
      state.current = null;
    }
  }
}

export function piOutputUsage(turn, now = performance.now()) {
  const state = requests.get(turn);
  if (!state) return {};
  const current = state.current;
  const live = current?.output > 0 && now > current.started;
  const output = state.output + (live ? current.output : 0);
  const duration = state.duration + (live ? now - current.started : 0);
  if (output <= 0 || duration <= 0) return {};
  return { turnTokenUsage: {
    usageScope: 'main_agent', usageStatus: 'partial', hasSubagents: false,
    inputTokens: state.input + (live ? current.input : 0), outputTokens: output,
    assistantDurationMs: duration,
  } };
}
