import assert from 'node:assert/strict';
import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
import * as Option from 'effect/Option';
import * as SqlClient from 'effect/sql/SqlClient';
import { CommandId, ProviderSessionId, RunId, RuntimeRequestId, ThreadId } from '@t3tools/contracts';
import * as Sqlite from '../../upstream/apps/server/src/persistence/Sqlite.ts';
import * as Outbox from '../../upstream/apps/server/src/orchestration-v2/EffectOutbox.ts';

// 使用正式迁移、真实 SQLite 事务和生产 claim 路径，重现恢复等待确认时的互锁。
export async function verifyResponseLane() {
  const layer = Outbox.layer.pipe(Layer.provideMerge(Sqlite.layerMemory));
  await Effect.runPromise(Effect.gen(function* () {
    const outbox = yield* Outbox.EffectOutboxV2;
    const sql = yield* SqlClient.SqlClient;
    yield* sql.withTransaction(Effect.gen(function* () {
      const threadId = ThreadId.make('thread:resume-dialog');
      const commandId = CommandId.make('command:resume-dialog');
      const providerSessionId = ProviderSessionId.make('session:resume-dialog');
      const enqueue = (id: string, request: Outbox.OrchestrationEffectRequestV2) =>
        outbox.enqueue([{ id, threadId, commandId, request }]);
      const claim = (workerId: string) => outbox.claimNext({ workerId, leaseDurationMs: 30000 });
      const expectClaim = (claimed: Option.Option<Outbox.OrchestrationEffectV2>, id: string) => {
        assert(Option.isSome(claimed), `${id} must not wait for the lifecycle dialog it answers`);
        assert.equal(claimed.value.id, id);
      };
      yield* enqueue('start', { type: 'provider-turn.start', runId: RunId.make('run:resume-dialog') });
      expectClaim(yield* claim('lifecycle'), 'start');
      // 排在回答前的普通工作不能被放行，也不能反过来挡住弹窗回答。
      yield* enqueue('cleanup', { type: 'terminal.cleanup' });
      yield* enqueue('answer', { type: 'runtime-request.respond', providerSessionId,
        requestId: RuntimeRequestId.make('request:resume'), decision: 'decline' });
      assert(Option.isSome(yield* outbox.nextClaimableAt));
      expectClaim(yield* claim('response'), 'answer');
      yield* enqueue('answer-next', { type: 'runtime-request.respond', providerSessionId,
        requestId: RuntimeRequestId.make('request:clear'), decision: 'accept' });
      assert(Option.isNone(yield* claim('blocked')), 'responses remain serial; ordinary work still waits');
      // 回答重试的退避仍须阻止后续回答，不得逆序发送。
      yield* outbox.retry({ effectId: 'answer', workerId: 'response', error: 'temporary', delayMs: 60000 });
      assert(Option.isNone(yield* claim('backoff')));
      yield* sql`UPDATE orchestration_v2_effect_outbox SET available_at = '2000-01-01T00:00:00.000Z' WHERE effect_id = 'answer'`;
      expectClaim(yield* claim('response'), 'answer');
      assert(yield* outbox.succeed({ effectId: 'answer', workerId: 'response' }));
      expectClaim(yield* claim('response'), 'answer-next');
      assert(yield* outbox.succeed({ effectId: 'answer-next', workerId: 'response' }));
      assert(Option.isNone(yield* claim('still-waiting')), 'ordinary work cannot bypass lifecycle');
      assert(yield* outbox.succeed({ effectId: 'start', workerId: 'lifecycle' }));
      expectClaim(yield* claim('ordinary'), 'cleanup');
      assert(yield* outbox.succeed({ effectId: 'cleanup', workerId: 'ordinary' }));
      return yield* Effect.fail('rollback-fixture' as const);
    })).pipe(Effect.catch(error => {
      assert.equal(error, 'rollback-fixture');
      return Effect.void;
    }));
    const rows = yield* sql`SELECT effect_id FROM orchestration_v2_effect_outbox`;
    assert.equal(rows.length, 0, 'fixture transaction must roll back');
  }).pipe(Effect.provide(layer), Effect.scoped));
}
