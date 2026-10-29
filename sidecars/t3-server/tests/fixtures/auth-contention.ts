import assert from 'node:assert/strict';
import * as NodeServices from '@effect/platform-node/NodeServices';
import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
import * as Deferred from 'effect/Deferred';
import * as Fiber from 'effect/Fiber';
import * as Option from 'effect/Option';
import * as HttpApiBuilder from 'effect/http-api/HttpApiBuilder';
import * as HttpApi from 'effect/http-api/HttpApi';
import { EnvironmentHttpApi } from '@t3tools/contracts';
import * as Logger from 'effect/Logger';
import * as SqlClient from 'effect/sql/SqlClient';
import * as NodeSqliteClient from '../../upstream/packages/shared/src/nodeSqliteClient.ts';
import { HttpServerRequest, HttpRouter, HttpServer } from 'effect/http';
import * as AuthHttp from '../../upstream/apps/server/src/auth/http.ts';
import { configureNative } from '../../native.mjs';
import * as EnvironmentAuth from '../../upstream/apps/server/src/auth/EnvironmentAuth.ts';
import * as ServerConfig from '../../upstream/apps/server/src/config.ts';

// 使用真实落盘数据库、正式签发/校验/撤销代码；由 Deferred 控制争用，不依赖大数据或 sleep 猜时序。
export async function verifyUnderContention(directory: string, lane: 'reader' | 'writer' | 'both', signal: AbortSignal) {
  const layer = EnvironmentAuth.layerRuntime.pipe(
    Layer.provideMerge(ServerConfig.layerTest(directory, directory)),
    Layer.provideMerge(NodeServices.layer),
    Layer.provide(Logger.layer([])),
  );
  return Effect.runPromise(Effect.gen(function* () {
    const auth = yield* EnvironmentAuth.EnvironmentAuth;
    const sql = yield* SqlClient.SqlClient;
    const native = configureNative({ environmentId: 'auth-contention-test', directory, accounts: undefined });
    yield* Effect.addFinalizer(() => Effect.sync(() => native.close()));
    const context = yield* Effect.context<Layer.Success<typeof layer>>();
    const api = HttpApi.make('environment').add(EnvironmentHttpApi.groups.auth);
    const http = HttpRouter.toWebHandler(HttpApiBuilder.layer(api).pipe(
      Layer.provide(AuthHttp.layer),
      Layer.provide(AuthHttp.layerAuthenticatedAuth),
      Layer.provide(HttpServer.layerServices),
      Layer.provide(Layer.succeedContext(context)),
    ), { disableLogger: true });
    yield* Effect.addFinalizer(() => Effect.promise(() => http.dispose()));
    const session = yield* auth.issueSession({ subject: 'auth-contention-test' });
    const webRequest = () => new Request('http://127.0.0.1/api/auth/session', {
      headers: { authorization: `Bearer ${session.token}` },
    });
    const request = HttpServerRequest.fromWeb(webRequest());
    const readHttpSession = Effect.promise(async () => {
      const response = await http.handler(webRequest(), context);
      assert.equal(response.status, 200);
      return response.json() as Promise<{ authenticated: boolean }>;
    });
    // 首次 HTTP 鉴权发生在争用已建立之后，不能提前预热凭证 reader 掩盖冷启动问题。
    const started = yield* Deferred.make<void>();
    const release = yield* Deferred.make<void>();
    const transaction = (ready: Deferred.Deferred<void>) => sql.withTransaction(Effect.gen(function* () {
      yield* sql`SELECT 1`;
      yield* Deferred.succeed(ready, undefined);
      yield* Deferred.await(release);
    }));
    const held = yield* (lane === 'writer' ? transaction(started) : NodeSqliteClient.readOnly(transaction(started)))
      .pipe(Effect.forkScoped);
    yield* Deferred.await(started);
    const writerStarted = yield* Deferred.make<void>();
    const extraWriter = lane === 'both' ? yield* transaction(writerStarted).pipe(Effect.forkScoped) : undefined;
    if (extraWriter) yield* Deferred.await(writerStarted);
    const before = performance.now();
    const result = yield* readHttpSession.pipe(
      Effect.timeoutOption('1 second'),
      Effect.ensuring(Deferred.succeed(release, undefined)),
    );
    const elapsedMs = Math.round(performance.now() - before);
    yield* Fiber.join(held);
    if (extraWriter) yield* Fiber.join(extraWriter);
    console.log(JSON.stringify({ lane, authenticationMs: elapsedMs }));
    assert(Option.isSome(result), `authentication blocked behind unrelated ${lane} transaction`);
    assert.equal(result.value.authenticated, true);
    // 损坏数据必须返回执行失败，而不是伪装成「未登录」；写入仅在测试事务中，随后回滚。
    yield* sql.withTransaction(Effect.gen(function* () {
      yield* sql`UPDATE auth_sessions SET scopes = '{}' WHERE session_id = ${session.sessionId}`;
      const failure = yield* Effect.exit(auth.getSessionState(request));
      assert.equal(failure._tag, 'Failure', 'corrupt auth data must not become an unauthenticated success');
      return yield* Effect.fail('rollback-corrupt-session');
    })).pipe(Effect.catch(reason => {
      assert.equal(reason, 'rollback-corrupt-session');
      return Effect.void;
    }));
    assert.equal((yield* readHttpSession).authenticated, true);
    yield* auth.revokeSession(session.sessionId);
    assert.equal((yield* readHttpSession).authenticated, false, 'revocation must remain observable');
    // 实际写事务回滚，结束后不能残留测试会话。
    let rolledBack: HttpServerRequest.HttpServerRequest | undefined;
    yield* sql.withTransaction(Effect.gen(function* () {
      const transient = yield* auth.issueSession({ subject: 'rolled-back-test' });
      const transientRequest = HttpServerRequest.fromWeb(new Request('http://127.0.0.1/api/auth/session', {
        headers: { authorization: `Bearer ${transient.token}` },
      }));
      assert.equal((yield* auth.getSessionState(transientRequest)).authenticated, true);
      rolledBack = transientRequest;
      return yield* Effect.fail('rollback-issued-session');
    })).pipe(Effect.catch(reason => {
      assert.equal(reason, 'rollback-issued-session');
      return Effect.void;
    }));
    assert(rolledBack);
    assert.equal((yield* auth.getSessionState(rolledBack)).authenticated, false);
  }).pipe(Effect.provide(layer), Effect.scoped), { signal });
}
