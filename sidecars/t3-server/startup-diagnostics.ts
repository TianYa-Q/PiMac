import path from 'node:path';
import { randomUUID } from 'node:crypto';
import * as Effect from 'effect/Effect';
import * as Exit from 'effect/Exit';
import { appendPrivateLog } from './connection-diagnostics.mjs';

export function createStartupDiagnostics(directory: string | undefined) {
  const file = directory === undefined ? undefined : path.join(directory, 'startup-diagnostics.log');
  const launchId = randomUUID();
  const started = performance.now();
  return {
    record(phase: string, state: 'start' | 'success' | 'failure', durationMs: number | null) {
      if (!/^[a-zA-Z0-9_.-]{1,120}$/.test(phase)) return;
      const elapsedMs = Math.round(performance.now() - started);
      // 鉴权轮询常驻运行，只记录启动前两分钟，避免持续写盘并挤掉启动阶段证据。
      if (phase.startsWith('auth.') && elapsedMs > 120000) return;
      const record = { launchId, pid: process.pid, phase, state,
        elapsedMs, processMs: Math.round(process.uptime() * 1000),
        ...(durationMs === null ? {} : { durationMs: Math.round(durationMs) }) };
      appendPrivateLog(file, `${new Date().toISOString()} ${JSON.stringify(record)}\n`, 512 * 1024);
    },
  };
}

// 只观察实际 Effect 的开始/结束；保留成功、失败与取消，不另建启动调度器。
// 即使某阶段挂起，也能凭最后一个 start 定位；日志不带用户消息、授权 URL 或令牌。
export function traceStartupPhase<A, E, R>(
  phase: string, effect: Effect.Effect<A, E, R>, diagnostics: ReturnType<typeof createStartupDiagnostics>,
): Effect.Effect<A, E, R> {
  return Effect.suspend(() => {
    const start = performance.now();
    diagnostics.record(phase, 'start', null);
    return effect.pipe(Effect.onExit(exit => Effect.sync(() => {
      diagnostics.record(phase, Exit.isSuccess(exit) ? 'success' : 'failure', performance.now() - start);
    })));
  });
}
