import * as Effect from 'effect/Effect';
import * as Schema from 'effect/Schema';
import { HttpRouter, HttpServerResponse } from 'effect/http';
import { ThreadId } from '@t3tools/contracts';
import { ProjectionStoreV2 } from './upstream/apps/server/src/orchestration-v2/ProjectionStore.ts';
import { ProviderSessionManagerV2 } from './upstream/apps/server/src/orchestration-v2/ProviderSessionManager.ts';
import { RuntimePolicyV2 } from './upstream/apps/server/src/orchestration-v2/RuntimePolicy.ts';

// 恢复由官方 session manager 执行；不发送 prompt、不创建 run、不走 JSONL 离线降级。
export const sessionHtmlExport = (threadId: ThreadId) => Effect.gen(function* () {
  const projections = yield* ProjectionStoreV2;
  const sessions = yield* ProviderSessionManagerV2;
  const policies = yield* RuntimePolicyV2;
  const projection = yield* projections.getThreadProjection(threadId);
  const thread = projection.thread;
  const providerThread = projection.providerThreads.find(p => p.id === thread.activeProviderThreadId);
  if (!providerThread || providerThread.driver !== 'pi') {
    return HttpServerResponse.jsonUnsafe({ error: '此会话尚无可导出的 Pi 会话记录。' }, { status: 409 });
  }
  if (!providerThread.nativeThreadRef?.nativeId || !providerThread.providerSessionId) {
    return HttpServerResponse.jsonUnsafe({ error: 'Pi 会话恢复信息缺失，无法导出。' }, { status: 409 });
  }
  const runtimePolicy = yield* policies.resolve({ thread, modelSelection: thread.modelSelection });
  const saved = projection.providerSessions.find(p => p.id === providerThread.providerSessionId);
  const session = yield* sessions.open({
    threadId, providerSessionId: providerThread.providerSessionId,
    modelSelection: thread.modelSelection, runtimePolicy,
    ...(saved === undefined ? {} : { resumeFromSession: saved }),
  });
  if (!session.exportThreadHtml) {
    return HttpServerResponse.jsonUnsafe({ error: '当前 Server 不支持 Pi HTML 导出，请更新后重试。' }, { status: 409 });
  }
  const html = yield* session.exportThreadHtml({ providerThread });
  // HTML 包含系统提示词和工具数据，只作为下载内容返回，不在 Server 页面中执行或缓存。
  return HttpServerResponse.jsonUnsafe({ html }, { headers: { 'cache-control': 'no-store' } });
});

export const makeSessionHtmlExportRoute = <E, R>(authenticate: Effect.Effect<void, E, R>) =>
  HttpRouter.add('POST', '/api/orchestration/threads/:threadId/export-html', Effect.gen(function* () {
    yield* authenticate;
    const params = yield* HttpRouter.params;
    const threadId = yield* Schema.decodeUnknownEffect(ThreadId)(params.threadId);
    return yield* sessionHtmlExport(threadId).pipe(
      Effect.catch(() => Effect.succeed(HttpServerResponse.jsonUnsafe(
        { error: '恢复或导出 Pi 会话失败；请确认会话文件、项目目录和 Pi 配置仍然可用后重试。' },
        { status: 409, headers: { 'cache-control': 'no-store' } },
      ))),
    );
  }));
