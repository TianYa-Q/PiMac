// Adapted read-only wire subset at the T3 baseline in runtime.mjs; MIT notice
// is in Resources/t3-bridge/T3-LICENSE.txt. Unsupported collections stay empty.
import * as Schema from 'effect/Schema';
import * as Rpc from 'effect/unstable/rpc/Rpc';
import * as RpcGroup from 'effect/unstable/rpc/RpcGroup';
import { SCOPES } from '../../Sources/PiMacApp/Resources/t3-bridge/protocol.mjs';
import { ServerConfig, ServerConfigStreamEvent, ServerLifecycleStreamEvent } from './upstream/server.ts';
import { ServerSettings } from './upstream/settings.ts';
import { DispatchResult, OrchestrationDispatchCommandError } from './upstream/orchestration.ts';
const id = Schema.NonEmptyString;
const integer = Schema.Int.check(Schema.isGreaterThanOrEqualTo(0));
const date = Schema.String;
const nullableDate = Schema.NullOr(date);
const empty = Schema.Array(Schema.Never);
export const AuthorizationError = Schema.Struct({
  _tag: Schema.Literal('EnvironmentAuthorizationError'), message: Schema.String,
  requiredScope: Schema.Literals(SCOPES),
});
export const SnapshotError = Schema.Struct({
  _tag: Schema.Literal('OrchestrationGetSnapshotError'), message: id,
});
const error = Schema.Union([AuthorizationError, SnapshotError]);
const model = Schema.Struct({ instanceId: id, model: id });
const session = Schema.NullOr(Schema.Struct({
  threadId: id, status: Schema.Literals(['running', 'ready', 'stopped']),
  providerName: Schema.NullOr(id), runtimeMode: Schema.Literal('full-access'),
  activeTurnId: Schema.Null, lastError: Schema.NullOr(id), updatedAt: date,
}));
const project = Schema.Struct({
  id, title: id, workspaceRoot: id, defaultModelSelection: Schema.NullOr(model),
  scripts: empty, createdAt: date, updatedAt: date,
});
const threadFields = {
  id, projectId: id, title: id, modelSelection: model,
  runtimeMode: Schema.Literal('full-access'), interactionMode: Schema.Literal('default'),
  branch: Schema.Null, worktreePath: Schema.Null, latestTurn: Schema.Null,
  createdAt: date, updatedAt: date, archivedAt: nullableDate,
  settledOverride: Schema.Null, settledAt: nullableDate, activeOrderKey: id, session,
};
const shellThread = Schema.Struct({
  ...threadFields, latestUserMessageAt: nullableDate, hasPendingApprovals: Schema.Boolean,
  hasPendingUserInput: Schema.Boolean, hasActionableProposedPlan: Schema.Boolean,
});
const message = Schema.Struct({
  id, role: Schema.Literals(['user', 'assistant', 'reasoning', 'system']),
  text: Schema.String, turnId: Schema.Null, streaming: Schema.Boolean,
  createdAt: date, updatedAt: date,
});
const activity = Schema.Struct({
  id, tone: Schema.Literals(['tool', 'info', 'error']), kind: id, summary: id,
  payload: Schema.Unknown, turnId: Schema.Null, createdAt: date,
});
const thread = Schema.Struct({
  ...threadFields, deletedAt: nullableDate, messages: Schema.Array(message),
  proposedPlans: empty, activities: Schema.Array(activity), checkpoints: empty,
});
export const ShellSnapshot = Schema.Struct({
  snapshotSequence: integer, projects: Schema.Array(project), threads: Schema.Array(shellThread), updatedAt: date,
});
export const ThreadSnapshot = Schema.Struct({ snapshotSequence: integer, thread });
const marker = Schema.Struct({ kind: Schema.Literal('synchronized') });
const shellItem = Schema.Union([marker, Schema.Struct({ kind: Schema.Literal('snapshot'), snapshot: ShellSnapshot })]);
const threadItem = Schema.Union([marker, Schema.Struct({ kind: Schema.Literal('snapshot'), snapshot: ThreadSnapshot })]);
export const ShellInput = Schema.Struct({
  afterSequence: Schema.optionalKey(integer), requestCompletionMarker: Schema.optionalKey(Schema.Boolean),
});
export const ThreadInput = Schema.Struct({
  threadId: id, reasoningMessages: Schema.optionalKey(Schema.Boolean),
  afterSequence: Schema.optionalKey(integer), requestCompletionMarker: Schema.optionalKey(Schema.Boolean),
  turnLimit: Schema.optionalKey(Schema.Int.check(Schema.isGreaterThanOrEqualTo(1))),
});
export const readGroup = RpcGroup.make(
  Rpc.make('server.probe', { payload: Schema.Struct({}), success: Schema.Struct({}), error: AuthorizationError }),
  Rpc.make('server.getConfig', { payload: Schema.Struct({}), success: ServerConfig, error: AuthorizationError }),
  Rpc.make('server.getSettings', { payload: Schema.Struct({}), success: ServerSettings, error: AuthorizationError }),
  Rpc.make('subscribeServerConfig', { payload: Schema.Struct({ environmentThemes: Schema.optionalKey(Schema.Boolean),
    usageLimitSources: Schema.optionalKey(Schema.Boolean), usageLimitsCommand: Schema.optionalKey(Schema.Boolean) }),
    success: ServerConfigStreamEvent, error: AuthorizationError, stream: true }),
  Rpc.make('subscribeServerLifecycle', { payload: Schema.Struct({}), success: ServerLifecycleStreamEvent, error: AuthorizationError, stream: true }),
  // Decode broadly so unsupported commands get a typed refusal instead of a
  // transport defect; commands.mjs validates the narrow existing-thread subset.
  Rpc.make('orchestration.dispatchCommand', { payload: Schema.Unknown, success: DispatchResult,
    error: Schema.Union([AuthorizationError, OrchestrationDispatchCommandError]) }),
  Rpc.make('orchestration.subscribeShell', { payload: ShellInput, success: shellItem, error, stream: true }),
  Rpc.make('orchestration.subscribeThread', { payload: ThreadInput, success: threadItem, error, stream: true }),
);
