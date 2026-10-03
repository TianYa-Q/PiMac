// Test-only harness for the patched official connector supervisor; no relay/network.
import assert from 'node:assert/strict';
import * as Effect from 'effect/Effect';
import * as Deferred from 'effect/Deferred';
import * as Queue from 'effect/Queue';
import * as Stream from 'effect/Stream';
import * as Sink from 'effect/Sink';
import * as Logger from 'effect/Logger';
import * as RelayClient from '@t3tools/shared/relayClient';
import * as ChildProcessSpawner from 'effect/unstable/process/ChildProcessSpawner';
import { make } from '../../upstream/apps/server/src/cloud/ManagedEndpointRuntime.ts';
import { configureNative } from '../../native.mjs';

export async function exerciseTunnelRuntime() {
  const broker = configureNative({ environmentId: 'test-connector' });
  const children = [], connectorOutput = [];
  broker.connectionDiagnostics.recordConnectorOutput = (pid, output) => connectorOutput.push({ pid, output });
  const program = Effect.gen(function* () {
    const runtime = yield* make;
    const config = { providerKind: 'cloudflare_tunnel', connectorToken: 'private-fixture-token' };
    const wait = predicate => Effect.gen(function* () {
      for (let n = 0; n < 200; n++) {
        if (predicate()) return;
        yield* Effect.sleep('5 millis');
      }
      throw new Error('Connector state timed out');
    });
    assert.equal((yield* runtime.applyConfig(config)).status, 'running');
    assert.equal(broker.tunnelHealth.status, 'connecting');
    yield* Queue.offer(children[0].output, new TextEncoder().encode('INF Registered tunnel connection connIndex=0\n'));
    yield* wait(() => broker.tunnelHealth.status === 'connected');
    yield* runtime.applyConfig(config);
    assert.equal(children.length, 1);
    assert.equal(broker.tunnelHealth.status, 'connected');
    children[0].running = false;
    yield* Deferred.succeed(children[0].exited, ChildProcessSpawner.ExitCode(1));
    yield* wait(() => children.length === 2);
    assert.equal(broker.tunnelHealth.status, 'connecting');
    yield* Queue.offer(children[1].output, new TextEncoder().encode('ERR Register tunnel error from server side error="Failed to get tunnel" private-fixture-token\n'));
    yield* wait(() => broker.tunnelHealth.status === 'reconnecting');
    yield* Queue.offer(children[1].output, new TextEncoder().encode('INF Registered tunnel connection connIndex=1\n'));
    yield* wait(() => broker.tunnelHealth.status === 'connected');
    yield* runtime.applyConfig(null);
    assert.equal(broker.tunnelHealth.status, 'disabled');
    assert(children.every(child => !child.running));
    assert(!broker.connectionDiagnostics.summary.includes('private-fixture-token'));
    assert(connectorOutput.some(entry => entry.output.includes('Failed to get tunnel')));
    assert(!JSON.stringify(connectorOutput).includes('private-fixture-token'));
  });
  const spawn = () => Effect.gen(function* () {
    const child = { running: true, output: yield* Queue.unbounded(), exited: yield* Deferred.make() };
    children.push(child);
    return yield* Effect.acquireRelease(Effect.succeed(ChildProcessSpawner.makeHandle({
      pid: ChildProcessSpawner.ProcessId(children.length),
      exitCode: Deferred.await(child.exited), isRunning: Effect.sync(() => child.running),
      kill: () => Effect.sync(() => { child.running = false; }), unref: Effect.succeed(Effect.void),
      stdin: Sink.drain, stdout: Stream.empty, stderr: Stream.empty, all: Stream.fromQueue(child.output),
      getInputFd: () => Sink.drain, getOutputFd: () => Stream.empty,
    })), () => Effect.sync(() => { child.running = false; }));
  });
  try {
    await Effect.runPromise(program.pipe(
      Effect.scoped,
      Effect.provideService(ChildProcessSpawner.ChildProcessSpawner, ChildProcessSpawner.make(spawn)),
      Effect.provideService(RelayClient.RelayClient, { resolve: Effect.succeed({ status: 'available', executablePath: '/unused' }) }),
      Effect.provide(Logger.layer([])),
    ));
  } finally { broker.close(); }
}
