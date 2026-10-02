// T3 owns orchestration, persistence and commands. This driver owns only Pi runtimes.
import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import * as Effect from 'effect/Effect';
import * as PubSub from 'effect/PubSub';
import * as Stream from 'effect/Stream';
import * as Schedule from 'effect/Schedule';
import * as Schema from 'effect/Schema';
import { ProviderRuntimeEvent, ProviderSession, ServerProvider, ProviderDriverKind } from '@t3tools/contracts';
import { ServerConfig } from './upstream/apps/server/src/config.ts';
import { ProviderAdapterRequestError, ProviderAdapterValidationError } from './upstream/apps/server/src/provider/Errors.ts';
import { defaultProviderContinuationIdentity } from './upstream/apps/server/src/provider/ProviderDriver.ts';
import { mergeProviderInstanceEnvironment } from './upstream/apps/server/src/provider/ProviderInstanceEnvironment.ts';
import { PiRPC } from './pi-rpc.mjs';
import { OutputSpeed } from './output-speed.mjs';
import { recordAccountStatus } from './account-status.mjs';
import { registerSessionMetrics, supportedThinkingLevels } from './session-metrics.mjs';
import { resolveAttachmentPath } from './upstream/apps/server/src/attachmentStore.ts';

const now = () => new Date().toISOString();
const decodeEvent = Schema.decodeUnknownSync(ProviderRuntimeEvent);
const decodeSession = Schema.decodeUnknownSync(ProviderSession);
const decodeSnapshot = Schema.decodeUnknownSync(ServerProvider);
const validation = (operation, issue) => new ProviderAdapterValidationError({ provider: 'pi', operation, issue });
const attempt = (operation, fn) => Effect.tryPromise({ try: fn, catch: error =>
  error?._tag === 'ProviderAdapterValidationError' ? error : new ProviderAdapterRequestError({ provider: 'pi', method: operation,
    detail: 'Pi operation failed or its outcome is unknown. No automatic retry was performed.' }) });

export const ServerOwnedPiDriver = {
  driverKind: ProviderDriverKind.make('pi'),
  metadata: { displayName: 'Pi', supportsMultipleInstances: true },
  configSchema: Schema.Struct({ binaryPath: Schema.optional(Schema.String), binaryArgs: Schema.optional(Schema.Array(Schema.String)) }),
  defaultConfig: () => ({}),
  create: ({ instanceId, enabled, displayName, environment, config }) => Effect.gen(function* () {
    const serverConfig = yield* ServerConfig;
    const topic = yield* PubSub.unbounded();
    const sessions = new Map(); const starting = new Map(); const probes = new Set();
    const directory = path.join(serverConfig.baseDir, 'pi-sessions', createHash('sha256').update(instanceId).digest('hex'));
    const env = { ...mergeProviderInstanceEnvironment(environment) };
    // Supervisor credentials must never reach agent tools or extensions.
    for (const key of Object.keys(env)) if (key.startsWith('PIMAC_T3_')) delete env[key];
    let stopping = false, cachedSnapshot, probing, discoveryRPC;
    const transport = (args, cwd, onEvent, onExit) => new PiRPC({ ...config, args, cwd, env, onEvent, onExit });
    const publish = (session, type, payload, refs = {}) => {
      if (stopping) return;
      PubSub.publishUnsafe(topic, decodeEvent({ eventId: randomUUID(), provider: 'pi', providerInstanceId: instanceId,
        threadId: session.info.threadId, createdAt: now(), ...(session.turnId ? { turnId: session.turnId } : {}), type, payload, ...refs }));
    };
    const update = (session, status) => { session.info = { ...session.info, status, updatedAt: now(),
      ...(session.turnId ? { activeTurnId: session.turnId } : {}) }; if (!session.turnId) delete session.info.activeTurnId; };
    const requireSession = threadId => {
      const session = sessions.get(threadId);
      if (!session || session.rpc.closed) throw validation('session', 'No active Pi session for this thread.');
      return session;
    };
    const finish = (session, state, errorMessage) => {
      if (!session.turnId) return;
      if (state === 'interrupted' || state === 'cancelled') publish(session, 'turn.aborted', { reason: state });
      else publish(session, 'turn.completed', { state, ...(errorMessage ? { errorMessage } : {}) });
      session.turnId = undefined; session.interrupted = false; session.failure = undefined;
      // T3's terminal event ingestion settles the native turn/session. A second
      // ready event would erase interruption/failure semantics in the projection.
      update(session, 'ready');
    };
    const onEvent = (session, event) => {
      recordAccountStatus(session.info.threadId, event);
      session.outputSpeed?.consume(event);
      if (event.type === 'extension_ui_request' && ['confirm', 'select', 'input', 'editor'].includes(event.method)) {
        // Dialog projection is a later slice. Fail closed rather than block or auto-approve.
        void session.rpc.write({ type: 'extension_ui_response', id: event.id, cancelled: true }).catch(() => {});
        publish(session, 'runtime.warning', { message: 'Pi extension dialog cancelled: this adapter does not yet support dialogs.' });
        return;
      }
      if (!session.turnId) return;
      if (event.type === 'agent_start') {
        update(session, 'running'); publish(session, 'session.state.changed', { state: 'running' });
      } else if (event.type === 'message_start' && event.message?.role === 'assistant') {
        session.itemId = randomUUID(); session.reasoningId = randomUUID();
        publish(session, 'item.started', { itemType: 'assistant_message' }, { itemId: session.itemId });
      } else if (event.type === 'message_update') {
        const delta = event.assistantMessageEvent;
        if (delta?.type === 'text_delta' || delta?.type === 'thinking_delta') publish(session, 'content.delta', {
          streamKind: delta.type === 'text_delta' ? 'assistant_text' : 'reasoning_text', delta: delta.delta,
          contentIndex: delta.contentIndex }, { itemId: delta.type === 'text_delta' ? session.itemId : session.reasoningId });
      } else if (event.type === 'message_end' && event.message?.role === 'assistant') {
        const message = event.message;
        const text = (message.content ?? []).filter(c => c.type === 'text').map(c => c.text).join('');
        const reasoning = (message.content ?? []).filter(c => c.type === 'thinking').map(c => c.thinking).join('');
        if (reasoning) publish(session, 'item.completed', { itemType: 'reasoning', detail: reasoning }, { itemId: session.reasoningId });
        publish(session, 'item.completed', { itemType: 'assistant_message', ...(text ? { detail: text } : {}), data: { usage: message.usage } }, { itemId: session.itemId });
        // Retry/compaction recovery can follow this message. Only agent_settled completes the T3 turn.
        session.failure = message.stopReason === 'error' ? 'Pi provider failed.' : undefined;
        if (message.stopReason === 'aborted') session.interrupted = true;
      } else if (event.type.startsWith('tool_execution_')) {
        const type = event.type === 'tool_execution_start' ? 'item.started' : event.type === 'tool_execution_end' ? 'item.completed' : 'item.updated';
        const result = event.result ?? event.partialResult;
        const content = Array.isArray(result?.content)
          ? result.content.filter(block => block.type === 'text').map(block => block.text).join('\n') : result?.content;
        publish(session, type, { itemType: 'dynamic_tool_call', title: event.toolName,
          status: event.type === 'tool_execution_end' ? (event.isError ? 'failed' : 'completed') : 'inProgress',
          data: { piTool: true, toolName: event.toolName, toolCallId: event.toolCallId, input: event.args,
            rawOutput: result ? { content } : undefined,
            ...(result?.nestedCalls ? { nestedCalls: result.nestedCalls } : {}),
            ...(result?.details?.diff ? { diff: result.details.diff } : {}),
            ...(event.args?.command ? { command: event.args.command } : {}) } }, { itemId: event.toolCallId });
      } else if (event.type === 'auto_retry_end' && event.success === false) {
        session.failure = 'Pi retries exhausted.';
      } else if (event.type === 'agent_settled') {
        void session.readMetrics().catch(() => {});
        finish(session, session.interrupted ? 'interrupted' : session.failure ? 'failed' : 'completed', session.failure);
      }
    };
    const selectModel = async (session, selection) => {
      if (!selection) return;
      if (selection.instanceId !== instanceId) throw validation('set_model', 'Model belongs to another provider instance.');
      const slash = selection.model.indexOf('/');
      if (slash < 1 || slash === selection.model.length - 1) throw validation('set_model', 'Expected provider/model Pi model slug.');
      const options = selection.options ?? [];
      for (const option of options) {
        if (option.id !== 'thinkingLevel' || !['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].includes(option.value))
          throw validation('set_model', 'Unsupported Pi model option.');
      }
      if (session.info.model !== selection.model) {
        await session.rpc.request({ type: 'set_model', provider: selection.model.slice(0, slash), modelId: selection.model.slice(slash + 1) });
        session.info.model = selection.model;
        session.thinkingLevel = undefined;
      }
      for (const option of options) if (session.thinkingLevel !== option.value) {
        await session.rpc.request({ type: 'set_thinking_level', level: option.value });
        session.thinkingLevel = option.value;
      }
    };
    const startSession = input => attempt('startSession', async () => {
      if (!enabled || stopping) throw validation('startSession', 'Pi provider is disabled or stopping.');
      if (input.runtimeMode !== 'full-access') throw validation('startSession', 'Pi does not implement T3 sandbox/approval modes. Use full-access explicitly.');
      if (!input.cwd || !fs.statSync(input.cwd).isDirectory()) throw validation('startSession', 'Workspace directory is required.');
      if (starting.has(input.threadId)) {
        const pending = starting.get(input.threadId);
        if (pending.signature !== JSON.stringify(input)) throw validation('startSession', 'Conflicting concurrent session start.');
        return pending.promise;
      }
      const existing = sessions.get(input.threadId);
      if (existing && !existing.rpc.closed) {
        if (existing.info.cwd !== input.cwd) throw validation('startSession', 'Cannot change the workspace of a live Pi session.');
        return decodeSession(existing.info);
      }
      const operation = (async () => {
        fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
        const stat = fs.lstatSync(directory);
        if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077))
          throw validation('startSession', 'Unsafe provider session directory.');
        const sessionId = 't3-' + createHash('sha256').update(input.threadId).digest('hex');
        if (input.resumeCursor && input.resumeCursor.sessionId !== sessionId) throw validation('startSession', 'Foreign Pi continuation cursor.');
        const createdAt = now();
        const session = { info: { provider: 'pi', providerInstanceId: instanceId, threadId: input.threadId, runtimeMode: input.runtimeMode,
          cwd: input.cwd, status: 'connecting', createdAt, updatedAt: createdAt, resumeCursor: { sessionId } } };
        session.rpc = transport(['--session-dir', directory, '--session-id', sessionId], input.cwd,
          event => onEvent(session, event), ({ expected }) => {
            if (sessions.get(input.threadId) !== session) return;
            finish(session, expected ? 'interrupted' : 'failed', expected ? undefined : 'Pi process exited before settlement.');
            update(session, 'closed'); publish(session, 'session.exited', { exitKind: expected ? 'graceful' : 'error', recoverable: !expected });
            session.removeMetrics?.();
            sessions.delete(input.threadId);
          });
        session.outputSpeed = new OutputSpeed();
        session.readMetrics = async () => {
          const stats = await session.rpc.request({ type: 'get_session_stats' });
          const context = stats?.contextUsage;
          if (Number.isSafeInteger(context?.tokens) && context.tokens >= 0) {
            const usage = { usedTokens: context.tokens };
            if (Number.isSafeInteger(context.contextWindow) && context.contextWindow > 0) usage.maxTokens = context.contextWindow;
            if (Number.isSafeInteger(stats.tokens?.total) && stats.tokens.total >= 0) usage.totalProcessedTokens = stats.tokens.total;
            const signature = JSON.stringify(usage);
            if (session.metricsSignature !== signature) {
              session.metricsSignature = signature;
              publish(session, 'thread.token-usage.updated', { usage });
            }
          }
          return { ...stats, outputTokensPerSecond: session.outputSpeed.value };
        };
        session.removeMetrics = registerSessionMetrics(input.threadId, session.readMetrics);
        sessions.set(input.threadId, session);
        try {
          await session.rpc.request({ type: 'get_state' });
          await selectModel(session, input.modelSelection);
          if (input.title) await session.rpc.request({ type: 'set_session_name', name: input.title });
          if (stopping) throw new Error('Provider stopping');
          update(session, 'ready'); publish(session, 'session.started', { resume: session.info.resumeCursor });
          publish(session, 'session.state.changed', { state: 'ready' });
          return decodeSession(session.info);
        } catch (error) { await session.rpc.stop(); sessions.delete(input.threadId); throw error; }
      })();
      starting.set(input.threadId, { signature: JSON.stringify(input), promise: operation });
      try { return await operation; } finally { starting.delete(input.threadId); }
    });
    const sendTurn = input => attempt('sendTurn', async () => {
      const session = requireSession(input.threadId);
      if (session.sending) throw validation('sendTurn', 'Pi is already submitting a prompt.');
      if (input.continuation || !input.input?.trim()) throw validation('sendTurn', 'An explicit text prompt is required.');
      const attachments = input.attachments ?? [];
      if (attachments.length > 8 || attachments.reduce((total, item) => total + item.sizeBytes, 0) > 8 * 1024 * 1024)
        throw validation('sendTurn', 'Pi supports up to 8 images / 8 MiB.');
      const images = attachments.map(attachment => {
        if (attachment.type !== 'image' || !['image/png', 'image/jpeg', 'image/webp'].includes(attachment.mimeType))
          throw validation('sendTurn', 'Only PNG/JPEG/WebP images are supported.');
        const file = resolveAttachmentPath({ attachmentsDir: serverConfig.attachmentsDir, attachment });
        if (!file) throw validation('sendTurn', 'Invalid attachment identity.');
        const fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
        try {
          const stat = fs.fstatSync(fd);
          if (!stat.isFile() || stat.size !== attachment.sizeBytes || stat.size > 8 * 1024 * 1024)
            throw validation('sendTurn', 'Attachment size mismatch.');
          return { type: 'image', mimeType: attachment.mimeType, data: fs.readFileSync(fd).toString('base64') };
        } finally { fs.closeSync(fd); }
      });
      if (input.interactionMode && input.interactionMode !== 'default') throw validation('sendTurn', 'Plan mode is not supported by Pi.');
      session.sending = true;
      try {
        // Native T3 sends another turn request to steer a running provider.
        // Preserve its identity and metrics; Pi owns delivery at the tool boundary.
        if (session.turnId) {
          const turnId = session.turnId;
          await session.rpc.request({ type: 'prompt', message: input.input, streamingBehavior: 'steer',
            ...(images.length ? { images } : {}) });
          return { threadId: input.threadId, turnId, resumeCursor: session.info.resumeCursor };
        }
        await selectModel(session, input.modelSelection);
        session.outputSpeed.reset();
        session.turnId = randomUUID(); const turnId = session.turnId;
        update(session, 'running'); publish(session, 'turn.started', { ...(session.info.model ? { model: session.info.model } : {}) });
        try {
          const result = await session.rpc.request({ type: 'prompt', message: input.input, ...(images.length ? { images } : {}) });
          if (result?.disposition === 'handled') finish(session, 'completed');
          else if (result?.disposition === 'queued') throw new Error('Unexpected queued prompt');
          return { threadId: input.threadId, turnId, resumeCursor: session.info.resumeCursor };
        } catch (error) {
          // Close the unknown-outcome runtime; never send this prompt again.
          finish(session, 'failed', 'Pi did not confirm submission.'); await session.rpc.stop(); throw error;
        }
      } finally { session.sending = false; }
    });
    const stopSession = threadId => attempt('stopSession', async () => {
      const session = sessions.get(threadId); if (session) await session.rpc.stop();
    });
    const stopAll = async () => {
      stopping = true;
      await Promise.all([...sessions.values()].map(s => s.rpc.stop()).concat([...probes].map(rpc => rpc.stop())));
      await Promise.allSettled([...starting.values()].map(value => value.promise));
      sessions.clear();
    };
    yield* Effect.addFinalizer(() => Effect.promise(stopAll));
    const probe = async () => {
      if (stopping) throw new Error('Provider stopping');
      // Keep the server-owned discovery runtime alive: account-usage refreshes
      // asynchronously and periodically, even before the first task is sent.
      const rpc = discoveryRPC && !discoveryRPC.closed ? discoveryRPC : transport(
        ['--no-session'], serverConfig.baseDir, event => {
          recordAccountStatus('@discovery', event);
          if (event.type === 'extension_ui_request' && ['confirm', 'select', 'input', 'editor'].includes(event.method)) {
            void rpc.write({ type: 'extension_ui_response', id: event.id, cancelled: true }).catch(() => {});
          }
        });
      discoveryRPC = rpc;
      probes.add(rpc);
      try {
        const result = await rpc.request({ type: 'get_available_models' });
        const state = await rpc.request({ type: 'get_state' });
        const current = state.model && `${state.model.provider}/${state.model.id}`;
        if (current && Array.isArray(result.models)) {
          result.models.sort((a, b) => Number(`${b.provider}/${b.id}` === current) - Number(`${a.provider}/${a.id}` === current));
        }
        return result;
      }
      catch (error) {
        await rpc.stop(); probes.delete(rpc);
        if (discoveryRPC === rpc) discoveryRPC = undefined;
        throw error;
      }
    };
    const snapshot = () => Effect.promise(async () => {
      if (cachedSnapshot) return cachedSnapshot;
      if (probing) return probing;
      probing = (async () => {
        let models = [], installed = false;
        if (enabled) try { models = (await probe()).models ?? []; installed = true; } catch {}
        cachedSnapshot = decodeSnapshot({ instanceId, driver: 'pi', displayName: displayName ?? 'Pi', enabled, installed, version: null,
          status: !enabled ? 'disabled' : installed ? 'ready' : 'error', availability: 'available', auth: { status: 'unknown' }, checkedAt: now(),
          supportsConversationRollback: false, supportsTextGeneration: false, requiresNewThreadForModelChange: false,
          setup: { canAuthenticate: false, canInstall: false }, models: models.map(m => ({ slug: m.provider + '/' + m.id,
            name: m.name ?? m.id, isCustom: false, capabilities: { optionDescriptors: [{
              id: 'thinkingLevel', label: 'Thinking level', type: 'select',
              options: supportedThinkingLevels(m).map(id => ({ id, label: id }))
            }] } })) });
        return cachedSnapshot;
      })();
      try { return await probing; } finally { probing = undefined; }
    });
    const unsupported = operation => () => Effect.fail(validation(operation, 'Not supported by the Pi provider adapter yet.'));
    return { instanceId, driverKind: 'pi', enabled, displayName,
      continuationIdentity: defaultProviderContinuationIdentity({ driverKind: 'pi', instanceId }),
      snapshot: { getSnapshot: snapshot(), refresh: () => { cachedSnapshot = undefined; return snapshot(); },
        streamChanges: Stream.fromEffect(snapshot()).pipe(Stream.repeat(Schedule.spaced('30 seconds'))),
        resolveMaintenance: () => Effect.succeed({ canInstall: false, canUpdate: false }), applyUsageLimits: () => Effect.void },
      adapter: { provider: 'pi', capabilities: { sessionModelSwitch: 'in-session', supportsConversationRollback: false },
        startSession, sendTurn, interruptTurn: (threadId, turnId) => attempt('interruptTurn', async () => {
          const session = requireSession(threadId);
          if (turnId && turnId !== session.turnId) throw validation('interruptTurn', 'Turn identity is stale.');
          session.interrupted = true; await session.rpc.request({ type: 'clear_queue' }); await session.rpc.request({ type: 'abort' });
          finish(session, 'interrupted');
        }), stopSession, stopAll: () => Effect.promise(stopAll),
        listSessions: () => Effect.sync(() => [...sessions.values()].map(s => decodeSession(s.info))),
        hasSession: threadId => Effect.sync(() => sessions.has(threadId) && !sessions.get(threadId).rpc.closed),
        respondToRequest: unsupported('respondToRequest'), respondToUserInput: unsupported('respondToUserInput'),
        readThread: unsupported('readThread'), rollbackThread: unsupported('rollbackThread'), streamEvents: Stream.fromPubSub(topic) },
      textGeneration: { generateCommitMessage: unsupported('generateCommitMessage'), generatePrContent: unsupported('generatePrContent'),
        generateBranchName: unsupported('generateBranchName'), generateThreadTitle: unsupported('generateThreadTitle') } };
  }),
};
