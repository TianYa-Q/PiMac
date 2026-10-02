// In-memory, bounded server delivery evidence, NOT proof of client rendering.
// Never retain URLs, headers, IDs, credentials, paths, text or arbitrary errors.
export function createReadDiagnostics() {
  const state = {
    shellHttpRequests: 0, shellHttpStatus: 0, catalogReads: 0, catalogFailures: 0,
    shellSubscriptions: 0, shellSnapshots: 0, shellCompletionMarkers: 0,
    lastRPC: 'none', lastFailure: 'none',
  };
  const methods = new Set(['server.probe', 'server.getConfig', 'server.getSettings',
    'subscribeServerConfig', 'subscribeServerLifecycle',
    'orchestration.subscribeShell', 'orchestration.subscribeThread', 'orchestration.dispatchCommand']);
  return {
    snapshot: () => ({ ...state }),
    httpStarted() { state.shellHttpRequests++; },
    httpFinished(status) {
      state.shellHttpStatus = status;
      if (status >= 400) state.lastFailure = 'shell_http_failed';
    },
    catalogStarted() { state.catalogReads++; },
    catalogFailed() { state.catalogFailures++; state.lastFailure = 'catalog_read_failed'; },
    rpc(method) { state.lastRPC = methods.has(method) ? method : 'unsupported'; },
    event(event) {
      if (event === 'shell_subscription') state.shellSubscriptions++;
      else if (event === 'shell_snapshot') state.shellSnapshots++;
      else if (event === 'shell_synchronized') state.shellCompletionMarkers++;
      else if (event === 'shell_stream_failed') state.lastFailure = event;
      else if (event === 'command_rejected') state.lastFailure = 'read_only_command';
    },
  };
}
