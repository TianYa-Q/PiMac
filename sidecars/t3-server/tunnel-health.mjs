// Read-only host health tracking; upstream owns all connector restart/recovery.
// Raw connector output (which can contain credentials) never leaves this parser.
export function createTunnelHealth(diagnostics) {
  let pid = null, state = 'disabled';
  const connections = new Set();
  const transition = next => {
    if (state === next) return;
    state = next;
    diagnostics.record('tunnel-health', { reason: next });
  };
  return {
    get status() { return state; },
    start(nextPID) {
      pid = nextPID; connections.clear(); transition('connecting');
    },
    stop(stoppedPID) {
      if (pid !== stoppedPID) return;
      pid = null; connections.clear(); transition('disabled');
    },
    exit(exitedPID) {
      if (pid !== exitedPID) return;
      pid = null; connections.clear(); transition('reconnecting');
    },
    output(sourcePID, line) {
      if (sourcePID !== pid) return;
      const index = /\bconnIndex=(\d+)\b/u.exec(line)?.[1];
      if (/You requested \d+ HA connections but I can give you at most \d+/u.test(line)) {
        diagnostics.record('tunnel-connector', { reason: 'edge-pool-reduced' });
      }
      if (/\bRegistered tunnel connection\b/iu.test(line)) {
        connections.add(index ?? 'unknown'); transition('connected');
      } else if (/\b(?:Unregistered tunnel connection|Connection terminated|Lost connection with the edge)\b/iu.test(line)) {
        if (index === undefined) connections.clear(); else connections.delete(index);
        if (!connections.size) transition('reconnecting');
      } else if (/\bRegister tunnel error from server side\b/iu.test(line)) {
        if (!connections.size) transition('reconnecting');
        diagnostics.record('tunnel-connector', { reason: 'registration-rejected' });
      } else if (/\b(?:ERR|FTL|PNC)\b/u.test(line)) {
        // A single edge's error does not invalidate the other live connections.
        diagnostics.record('tunnel-connector', { reason: 'transport-error' });
      }
    },
    config(status) {
      if (status.status === 'disabled' || status.status === 'unsupported' || status.status === 'failed') {
        pid = null; connections.clear();
        transition(status.status === 'failed' ? 'failed:' + status.failure : status.status);
      }
      // "running" is process liveness, never edge/public readiness.
    },
  };
}
