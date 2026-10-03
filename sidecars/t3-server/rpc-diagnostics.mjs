import * as Effect from 'effect/Effect';
import { getNative } from './native.mjs';

// Only schema-owned metadata is recorded. Never log error messages, payloads,
// headers or tokens. A received event means the RPC handler was actually entered.
export function observeNativeRpc(method, effect, attributes = {}, access = {}) {
  const fields = {
    method,
    commandId: attributes['orchestration_v2.command_id'],
    commandType: attributes['orchestration_v2.command_type'],
    threadId: attributes['orchestration_v2.thread_id'],
    dispatchMode: attributes['pimac.dispatch_mode'],
    deliveryIntent: attributes['pimac.delivery_intent'],
  };
  const record = (event, extra = {}) => {
    try { getNative().connectionDiagnostics.record(event, { ...fields, ...extra }); }
    catch { /* Diagnostics must never change RPC behavior. */ }
  };
  return Effect.sync(() => {
    record('rpc-received');
    if (access.allowed === false) record('rpc-denied', { reason: 'host-policy' });
    else if (access.authorized === false) record('rpc-denied', { reason: 'missing-scope' });
  }).pipe(
    Effect.andThen(effect),
    Effect.tap(() => Effect.sync(() => record('rpc-succeeded'))),
    Effect.tapError(error => Effect.sync(() => {
      const tags = [];
      for (let current = error, depth = 0; current && depth < 4; current = current.cause, depth++) {
        if (typeof current._tag === 'string' && /^[A-Za-z][A-Za-z0-9]{0,79}$/.test(current._tag)) tags.push(current._tag);
      }
      record('rpc-failed', { errorTags: tags.join('/') || 'UnknownError' });
    })),
  );
}
