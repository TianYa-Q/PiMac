// Test-only real Effect RPC client; not shipped in the application.
import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
import * as Logger from 'effect/Logger';
import * as Stream from 'effect/Stream';
import * as Socket from 'effect/unstable/socket/Socket';
import { WsRpcGroup as group } from '@t3tools/contracts';
import * as RpcClient from 'effect/unstable/rpc/RpcClient';
import * as RpcSerialization from 'effect/unstable/rpc/RpcSerialization';


export function call(url, method, input = {}) {
  return run(url, Effect.gen(function* () {
    const client = yield* RpcClient.make(group);
    return yield* client[method](input);
  }));
}
export function readStream(url, method, input, { count = 1, onItem = () => {} } = {}) {
  return run(url, Effect.gen(function* () {
    const client = yield* RpcClient.make(group);
    return yield* client[method](input).pipe(Stream.take(count),
      Stream.tap(item => Effect.promise(async () => onItem(item))), Stream.runCollect);
  }));
}
function run(url, effect) {
  return Effect.runPromise(effect.pipe(Effect.scoped, Effect.provide(RpcClient.layerProtocolSocket({ retryTransientErrors: false }).pipe(
    Layer.provide(RpcSerialization.layerJson),
    Layer.provide(Socket.layerWebSocket(url).pipe(Layer.provide(Socket.layerWebSocketConstructorGlobal))),
  )), Effect.provide(Logger.layer([]))), { signal: AbortSignal.timeout(10000) });
}
export function probe(url, count = 1) {
  const program = Effect.gen(function* () {
    const client = yield* RpcClient.make(group);
    return yield* Effect.all(Array.from({ length: count }, () => client['server.probe']({})), { concurrency: 'unbounded' });
  }).pipe(Effect.scoped, Effect.provide(RpcClient.layerProtocolSocket({ retryTransientErrors: false }).pipe(
    Layer.provide(RpcSerialization.layerJson),
    Layer.provide(Socket.layerWebSocket(url).pipe(Layer.provide(Socket.layerWebSocketConstructorGlobal))),
  )), Effect.provide(Logger.layer([])));
  return Effect.runPromise(program, { signal: AbortSignal.timeout(10000) });
}
