import { OrchestrationV2RpcSchemas } from '@t3tools/contracts';
import * as Schema from 'effect/Schema';
import { applyOrchestrationV2ProjectionEvent } from '../../third_party/t3code/packages/client-runtime/src/state/orchestrationV2Projection.ts';
import { applyShellStreamEvent, mergeShellSnapshotProjects } from '../../third_party/t3code/packages/client-runtime/src/state/shellReducer.ts';

type Kind = 'shell' | 'thread';
type Shell = typeof OrchestrationV2RpcSchemas.subscribeShell.output.Type;
type Thread = typeof OrchestrationV2RpcSchemas.subscribeThread.output.Type;
type ShellSnapshot = Extract<Shell, { kind: 'snapshot' }>['snapshot'];
type Projection = Extract<Thread, { kind: 'snapshot' }>['projection'];
const decodeShell = Schema.decodeUnknownSync(Schema.toCodecJson(OrchestrationV2RpcSchemas.subscribeShell.output));
const decodeThread = Schema.decodeUnknownSync(Schema.toCodecJson(OrchestrationV2RpcSchemas.subscribeThread.output));

/** 只适配传输与原生宿主；协议校验、列表合并和消息投影全部复用同版本官方实现。 */
export function createStreamState(kind: Kind) {
  let shell: ShellSnapshot | null = null;
  let projection: Projection | null = null;
  let sequence = -1;
  return {
    apply(json: string): boolean {
      const input: unknown = JSON.parse(json);
      if (kind === 'shell') {
        const item = decodeShell(input);
        if (item.kind === 'synchronized') return false;
        if (item.kind === 'snapshot') {
          shell = mergeShellSnapshotProjects(shell, item.snapshot,
            item.resolvedRepositoryIdentityRoots === undefined ? undefined : {
              resolvedRepositoryIdentityRoots: item.resolvedRepositoryIdentityRoots,
            });
          sequence = shell.snapshotSequence;
          return true;
        }
        if (shell === null) throw new Error('Shell event before snapshot');
        if (item.sequence <= sequence) return false;
        shell = applyShellStreamEvent(shell, item);
        sequence = shell.snapshotSequence;
        return true;
      }
      const item = decodeThread(input);
      if (item.kind === 'synchronized') return false;
      if (item.kind === 'snapshot') {
        // 不申请 bounded/compact/deduped 模式，保留已有原生历史展示契约。
        if (item.hasMoreHistory === true || item.turnItemsOmitLocalVisible === true) {
          throw new Error('Unexpected partial snapshot');
        }
        projection = item.projection;
        sequence = item.snapshotSequence;
        return true;
      }
      if (projection === null) throw new Error('Thread event before snapshot');
      if (item.sequence <= sequence) return false;
      sequence = item.sequence;
      if (item.kind === 'unknown-event') return false;
      const next = applyOrchestrationV2ProjectionEvent(projection, item.event);
      const changed = next !== projection;
      projection = next;
      return changed;
    },
    snapshot(): string {
      if (kind === 'shell') {
        if (shell === null) throw new Error('Shell snapshot unavailable');
        return JSON.stringify(shell);
      }
      if (projection === null) throw new Error('Thread snapshot unavailable');
      return JSON.stringify({ snapshotSequence: sequence, projection });
    },
  };
}
