import { AssetResource, CommandId, ComposerContextId, COMPOSER_CONTEXT_MAX_RECORDS, EnvironmentId, OrchestrationMessageContext, OrchestrationV2RpcSchemas, OrchestrationV2ThreadHistoryPage, ProjectId, ThreadContextRecord, ThreadId } from '@t3tools/contracts';
import { decodeComposerContextClipboardHtml, decodeComposerContextFragment, encodeComposerContextClipboardHtml, encodeComposerContextFragment } from '../../third_party/t3code/packages/shared/src/composerContextClipboard.ts';
import { collectComposerContextReferences, formatComposerContextReference, replaceComposerContextReferences, sanitizeComposerContextLabel, threadContextsOutsideEnvironment, toKindScopedComposerContextId } from '../../third_party/t3code/packages/shared/src/composerContextReferences.ts';
import { parseMarkdownFileLink } from '../../third_party/t3code/packages/shared/src/markdownLinks.ts';
import { filePreviewKind } from '../../third_party/t3code/packages/shared/src/filePreview.ts';
import * as Schema from 'effect/Schema';
import { boundedSnapshotProjection } from '../../third_party/t3code/packages/shared/src/orchestrationV2BoundedSnapshot.ts';
import { mergeOlderHistoryIntoProjection } from '../../third_party/t3code/packages/client-runtime/src/state/threadHistoryMerge.ts';
import { applyOrchestrationV2ProjectionEvent } from '../../third_party/t3code/packages/client-runtime/src/state/orchestrationV2Projection.ts';
import { applyShellStreamEvent, mergeShellSnapshotProjects } from '../../third_party/t3code/packages/client-runtime/src/state/shellReducer.ts';

import { findProjectByPath } from '../../third_party/t3code/packages/client-runtime/src/state/projects.ts';
import { buildProjectCreateCommand } from '../../third_party/t3code/packages/client-runtime/src/operations/projects.ts';

const decodeProjectPreparation = Schema.decodeUnknownSync(Schema.Struct({
  projects: Schema.Array(Schema.Struct({ id: ProjectId, workspaceRoot: Schema.String })),
  workspaceRoot: Schema.String,
  projectId: ProjectId,
  commandId: CommandId,
}));

/** 项目决策直接调用官方函数；宿主只提供当前环境的订阅状态与一次性命令身份。 */
export function prepareProject(json: string): string {
  const input = decodeProjectPreparation(JSON.parse(json));
  const existing = findProjectByPath(input.projects, input.workspaceRoot);
  return JSON.stringify(existing
    ? { projectId: existing.id }
    : { projectId: input.projectId, command: buildProjectCreateCommand(input) });
}

const decodeReplyDocument = Schema.decodeUnknownSync(Schema.Struct({
  href: Schema.String, threadId: Schema.String,
}));
const decodeAssetResource = Schema.decodeUnknownSync(AssetResource);

/** 原生端只转接显式本地链接；路径解析交给官方模块，工作区解析交给 Server。 */
export function prepareReplyDocument(json: string): string {
  const input = decodeReplyDocument(JSON.parse(json));
  // 官方对裸相对路径有自动识别启发式；显式点击的链接用 ./ 表明本地路径，支持中文文件名。
  const href = input.href.startsWith('/') || input.href.startsWith('~')
    ? input.href : './' + input.href;
  const target = parseMarkdownFileLink(href);
  if (target === null) throw new Error('Invalid local file link');
  const { path } = target;
  if (path.includes('\0') || path.endsWith('/')) throw new Error('Invalid local file path');
  const kind = filePreviewKind({ name: path });
  const resource = decodeAssetResource({
    _tag: 'media-file', threadId: input.threadId, path,
    ...(kind === 'html' || kind === 'pdf' ? {} : { disposition: 'attachment' }),
  });
  return JSON.stringify(resource);
}

const decodeThreadCopy = Schema.decodeUnknownSync(Schema.Struct({
  environmentId: EnvironmentId, threadId: ThreadId, title: Schema.String,
}));

/** 剪贴板同时写入官方 fragment 和 HTML fallback，兼容 iOS 与 Web。 */
export function prepareThreadCopy(json: string): string {
  const input = decodeThreadCopy(JSON.parse(json));
  const label = sanitizeComposerContextLabel(input.title, 'thread');
  const record = Schema.decodeUnknownSync(ThreadContextRecord)({
    version: 1, kind: 'thread', contextId: toKindScopedComposerContextId('thread', input.threadId),
    label, title: label, environmentId: input.environmentId, threadId: input.threadId,
  });
  const text = formatComposerContextReference(record);
  const fragment = encodeComposerContextFragment({ version: 1, source: { environmentId: input.environmentId }, records: [record] });
  if (fragment === null) throw new Error('Context is too large to copy');
  return JSON.stringify({ text, fragment, html: encodeComposerContextClipboardHtml(text, fragment) });
}

const decodeThreadPaste = Schema.decodeUnknownSync(Schema.Struct({
  text: Schema.String, fragment: Schema.String, html: Schema.String,
  environmentId: EnvironmentId, identity: ComposerContextId,
  existing: Schema.optional(OrchestrationMessageContext),
}));

/** 复用官方校验和引用解析；宿主仅分配新身份，防止多次粘贴覆盖旧快照。
 * 本入口只导入 thread，附件迁移需要独立上传链路，不能冒充已经支持。
 */
export function prepareThreadPaste(json: string): string {
  const input = decodeThreadPaste(JSON.parse(json));
  const fragment = decodeComposerContextFragment(input.fragment) ?? decodeComposerContextClipboardHtml(input.html);
  if (!fragment) throw new Error('Invalid context clipboard payload');
  const referenced = new Set(collectComposerContextReferences(input.text).map(ref => ref.contextId));
  const records = fragment.records.filter(record => referenced.has(record.contextId));
  if (records.some(record => record.kind !== 'thread' || !('threadId' in record))) {
    throw new Error('This paste entry supports thread references only');
  }
  if (threadContextsOutsideEnvironment({ text: input.text, records, environmentId: input.environmentId }).length) {
    throw new Error('Thread reference belongs to another environment');
  }
  const ids = new Map(records.map((record, index) => [record.contextId, ComposerContextId.make(`${input.identity}_${index}`)]));
  const imported = records.map(record => ({ ...record, contextId: ids.get(record.contextId)! }));
  const all = [...(input.existing?.records ?? []), ...imported];
  const context = Schema.decodeUnknownSync(OrchestrationMessageContext)({ version: 1, records: all });
  return JSON.stringify({
    text: replaceComposerContextReferences(input.text, ref => formatComposerContextReference({ ...ref, contextId: ids.get(ref.contextId) ?? ref.contextId })),
    context,
  });
}

const decodeContextDispatch = Schema.decodeUnknownSync(Schema.Struct({
  text: Schema.String, context: Schema.optional(OrchestrationMessageContext), environmentId: EnvironmentId,
}));

/** 只发送正文实际引用的记录；缺失的记录由官方 Server 明确标为 unavailable。 */
export function prepareContextDispatch(json: string): string {
  const input = decodeContextDispatch(JSON.parse(json));
  const ids = new Set(collectComposerContextReferences(input.text).map(ref => ref.contextId));
  // 与官方 composer 一致，预览注释的截图是间接依赖，不能在重新编辑后被当成孤立记录丢掉。
  for (const record of input.context?.records ?? []) {
    if (ids.has(record.contextId) && record.kind === 'preview-annotation'
      && 'screenshotContextId' in record && record.screenshotContextId) ids.add(record.screenshotContextId);
  }
  const records = input.context?.records.filter(record => ids.has(record.contextId)) ?? [];
  if (records.length > COMPOSER_CONTEXT_MAX_RECORDS) throw new Error('Too many context records');
  if (threadContextsOutsideEnvironment({ text: input.text, records, environmentId: input.environmentId }).length) {
    throw new Error('Thread reference belongs to another environment');
  }
  return JSON.stringify(records.length ? { context: { version: 1, records } } : {});
}

type Kind = 'shell' | 'thread';
type Shell = typeof OrchestrationV2RpcSchemas.subscribeShell.output.Type;
type Thread = typeof OrchestrationV2RpcSchemas.subscribeThread.output.Type;
type ShellSnapshot = Extract<Shell, { kind: 'snapshot' }>['snapshot'];
type Projection = Extract<Thread, { kind: 'snapshot' }>['projection'];
const decodeShell = Schema.decodeUnknownSync(Schema.toCodecJson(OrchestrationV2RpcSchemas.subscribeShell.output));
const decodeThread = Schema.decodeUnknownSync(Schema.toCodecJson(OrchestrationV2RpcSchemas.subscribeThread.output));
const decodeHistoryPage = Schema.decodeUnknownSync(Schema.toCodecJson(OrchestrationV2ThreadHistoryPage));

/** 只适配传输与原生宿主；协议校验、列表合并和消息投影全部复用同版本官方实现。 */
export function createStreamState(kind: Kind) {
  let shell: ShellSnapshot | null = null;
  let projection: Projection | null = null;
  let sequence = -1;
  let historyCursor: string | null = null;
  let hasMoreHistory = false;
  let historyExpanded = false;
  let latestLocalTurnOrdinal: number | null = null;
  let historyRevision = 0;
  return {
    apply(json: string, preservingLiveSequence = false): boolean {
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
        if (preservingLiveSequence && item.snapshotSequence < sequence) return false;
        projection = boundedSnapshotProjection(item);
        historyCursor = item.historyCursor ?? null;
        hasMoreHistory = item.hasMoreHistory ?? false;
        historyExpanded = false;
        latestLocalTurnOrdinal = item.latestLocalTurnOrdinal ?? null;
        historyRevision += 1;
        sequence = item.snapshotSequence;
        return true;
      }
      if (projection === null) throw new Error('Thread event before snapshot');
      if (item.sequence <= sequence) return false;
      sequence = item.sequence;
      if (item.kind === 'unknown-event') return false;
      const partial = hasMoreHistory || historyCursor !== null
        ? { partialTimeline: true, latestLocalTurnOrdinal } : undefined;
      const next = applyOrchestrationV2ProjectionEvent(projection, item.event, partial);
      if (partial && item.event.type === 'turn-item.updated') {
        latestLocalTurnOrdinal = Math.max(latestLocalTurnOrdinal ?? 0, item.event.payload.ordinal);
      }
      const changed = next !== projection;
      projection = next;
      return changed;
    },
    mergeHistory(json: string, cursor: string, revision: number): boolean {
      // 正文增量可与历史请求并行；新快照或另一页已推进游标时，旧响应不能接回去。
      if (projection === null || historyCursor !== cursor || historyRevision !== revision) return false;
      const page = decodeHistoryPage(JSON.parse(json));
      if (page.hasMoreHistory && (page.nextCursor === null || page.nextCursor === cursor)) {
        throw new Error('History cursor did not advance');
      }
      projection = mergeOlderHistoryIntoProjection(projection, page.items);
      historyCursor = page.nextCursor;
      hasMoreHistory = page.hasMoreHistory;
      historyExpanded = true;
      historyRevision += 1;
      // 分页响应的序号不能覆盖实时事件游标；合并函数保留已到达的新版本。
      return true;
    },
    snapshot(): string {
      if (kind === 'shell') {
        if (shell === null) throw new Error('Shell snapshot unavailable');
        return JSON.stringify(shell);
      }
      if (projection === null) throw new Error('Thread snapshot unavailable');
      return JSON.stringify({ snapshotSequence: sequence, projection, historyCursor, hasMoreHistory, historyExpanded, historyRevision, latestLocalTurnOrdinal });
    },
  };
}
