import * as Effect from 'effect/Effect';
import * as Scope from 'effect/Scope';
import * as Exit from 'effect/Exit';
import * as Stream from 'effect/Stream';
import * as Fiber from 'effect/Fiber';
import { ServerOwnedPiDriver } from '../pi-provider.mjs';
import { ServerConfig } from '../upstream/apps/server/src/config.ts';

export async function providerFixture({ directory, config, instanceId = 'pi', enabled = true }) {
  const scope = await Effect.runPromise(Scope.make());
  const run = Effect.runPromise;
  const instance = await run(ServerOwnedPiDriver.create({ instanceId, enabled, config }).pipe(
    Effect.provideService(ServerConfig, { baseDir: directory }), Effect.provideService(Scope.Scope, scope)));
  const events = [];
  const fiber = Effect.runFork(Stream.runForEach(instance.adapter.streamEvents, event => Effect.sync(() => events.push(event))));
  // Ensure the PubSub subscription exists before invoking the adapter.
  await new Promise(resolve => setTimeout(resolve, 0));
  return { instance, adapter: instance.adapter, run, events,
    close: async () => { await run(Scope.close(scope, Exit.void)); await run(Fiber.interrupt(fiber)); } };
}
