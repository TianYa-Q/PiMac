import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import * as Effect from 'effect/Effect';
import { configureNative } from '../native.mjs';
import { observeNativeRpc } from '../rpc-diagnostics.mjs';

test('RPC arrival, queue mode, success and rejection are recorded without prompt or error text', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-rpc-log-'));
  const host = configureNative({ environmentId: 'test', directory });
  t.after(async () => { host.close(); await rm(directory, { recursive: true, force: true }); });
  const attributes = {
    'orchestration_v2.command_id': 'mobile-command-1',
    'orchestration_v2.command_type': 'message.dispatch',
    'orchestration_v2.thread_id': 'thread-1',
    'pimac.dispatch_mode': 'queue_after_active',
    'pimac.delivery_intent': 'queue',
    text: 'PRIVATE PROMPT',
  };
  assert.equal(await Effect.runPromise(observeNativeRpc('orchestration.dispatchCommand', Effect.succeed(42), attributes)), 42);
  const failure = { _tag: 'OrchestratorDispatchError', message: 'SECRET TOKEN AND PROMPT', cause: { _tag: 'ProviderError', message: 'PRIVATE' } };
  const result = await Effect.runPromise(observeNativeRpc('orchestration.dispatchCommand', Effect.fail(failure), attributes).pipe(Effect.result));
  assert.equal(result._tag, 'Failure');
  await Effect.runPromise(observeNativeRpc('orchestration.dispatchCommand', Effect.fail({ _tag: 'EnvironmentAuthorizationError' }), attributes, { allowed: false }).pipe(Effect.result));
  await Effect.runPromise(observeNativeRpc('orchestration.dispatchCommand', Effect.fail({ _tag: 'EnvironmentAuthorizationError' }), attributes, { allowed: true, authorized: false }).pipe(Effect.result));
  const log = await readFile(join(directory, 'connection-diagnostics.log'), 'utf8');
  assert.match(log, /rpc-received/);
  assert.match(log, /rpc-succeeded/);
  assert.match(log, /rpc-failed/);
  assert.match(log, /queue_after_active/);
  assert.match(log, /OrchestratorDispatchError\/ProviderError/);
  assert.match(log, /host-policy/);
  assert.match(log, /missing-scope/);
  assert.doesNotMatch(log, /PRIVATE|SECRET|TOKEN|PROMPT/);
});
