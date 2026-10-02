import { AuthFailure } from './auth-store.mjs';
import { jsonResponse } from './auth-http.mjs';
import { validateReadSnapshot } from './vendor/rpc-runtime.mjs';

export async function handleOrchestrationRead(req, res, store, workspace) {
  const url = new URL(req.url, 'http://127.0.0.1');
  const thread = /^\/api\/orchestration\/threads\/([^/]+)$/.exec(url.pathname);
  const shell = url.pathname === '/api/orchestration/shell';
  if (req.method !== 'GET' || (!shell && !thread)) return false;
  const session = store.authenticate(req.headers.authorization);
  store.requireScope(session, 'orchestration:read');
  if ([...url.searchParams.keys()].some(key => key !== 'reasoningMessages') ||
      url.searchParams.getAll('reasoningMessages').length > 1 ||
      (url.searchParams.has('reasoningMessages') && url.searchParams.get('reasoningMessages') !== 'true') ||
      (shell && url.search)) throw new AuthFailure(400, 'invalid_request', 'invalid_command');
  let snapshot;
  try {
    snapshot = shell ? await workspace.shellSnapshot()
      : await workspace.threadSnapshot(thread[1], { reasoningMessages: url.searchParams.get('reasoningMessages') === 'true' });
    snapshot = validateReadSnapshot(snapshot, shell ? 'shell' : 'thread');
  } catch {
    throw new AuthFailure(503, 'internal_error', shell ? 'orchestration_snapshot_failed' : 'orchestration_thread_snapshot_failed');
  }
  // Authorization is checked again AFTER IPC. Revoking a credential while the
  // desktop is reading must not release the delayed transcript to that client.
  const live = store.isLive(session.sessionId);
  if (!live) throw new AuthFailure(401, 'auth_invalid', 'invalid_credential');
  store.requireScope(live, 'orchestration:read');
  jsonResponse(res, 200, snapshot);
  return true;
}
