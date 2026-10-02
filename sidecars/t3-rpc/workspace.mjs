import { createHash, randomUUID } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
const epoch = '1970-01-01T00:00:00.000Z';
const hash = (...parts) => createHash('sha256').update(JSON.stringify(parts)).digest('hex');
const failure = () => ({ _tag: 'OrchestrationGetSnapshotError', message: 'Workspace read unavailable or exceeds preview limits' });
const budget = (value, limit = 512 * 1024) => {
  if (Buffer.byteLength(JSON.stringify(value)) > limit) throw failure();
  return value;
};

// A watermark, not a second transcript store. Commit before publishing so a
// restart or clock rollback cannot regress the sequence visible to clients.
class SequenceClock {
  constructor(environmentId, file) {
    this.environmentId = environmentId;
    this.file = file;
    this.value = Date.now() * 1000;
    let info;
    if (file) {
      try { info = fs.lstatSync(file); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    }
    if (info) {
      if (!info.isFile() || info.size > 4096 || info.uid !== process.getuid?.()) throw new Error('Unsafe projection clock');
      const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
      if (saved.environmentId !== environmentId || !Number.isSafeInteger(saved.sequence) || saved.sequence < 0) throw new Error('Invalid projection clock');
      fs.chmodSync(file, 0o600);
      this.value = Math.max(this.value, saved.sequence);
    }
  }
  next() {
    if (this.failed) throw failure();
    const sequence = this.value + 1;
    if (!Number.isSafeInteger(sequence)) throw failure();
    if (this.file) {
      const temp = `${this.file}.${randomUUID()}.tmp`;
      let fd;
      try {
        fd = fs.openSync(temp, 'wx', 0o600);
        fs.writeFileSync(fd, JSON.stringify({ environmentId: this.environmentId, sequence }));
        fs.fsyncSync(fd);
        fs.closeSync(fd); fd = undefined;
        fs.renameSync(temp, this.file);
        const dir = fs.openSync(path.dirname(this.file), 'r');
        try { fs.fsyncSync(dir); } finally { fs.closeSync(dir); }
      } catch { this.failed = true; throw failure(); }
      finally { if (fd !== undefined) fs.closeSync(fd); if (fs.existsSync(temp)) fs.unlinkSync(temp); }
    }
    this.value = sequence;
    return sequence;
  }
}

export class WorkspaceProjection {
  constructor({ environmentId, request, clockFile, intervalMs = 500 }) {
    this.environmentId = environmentId;
    this.request = request;
    this.clock = new SequenceClock(environmentId, clockFile);
    this.intervalMs = intervalMs;
    this.watchers = new Set();
    this.targets = new Map();
    this.activityTurns = [];
    this.details = new Map();
    this.messageAliases = new Map();
    this.sendingThreads = new Set();
    this.shell = null;
    this.models = [];
    this.defaultModelId = null;
    this.closed = false;
  }
  id(kind, ...parts) { return `pimac-${kind}-${hash(this.environmentId, kind, ...parts)}`; }
  async shellSnapshot() {
    await this.refresh();
    return { ...this.shell, snapshotSequence: this.clock.value };
  }
  async threadSnapshot(id, { reasoningMessages = false, turnLimit } = {}, refresh = true) {
    if (turnLimit !== undefined) throw failure(); // No false pagination advertisement.
    if (refresh) await this.refresh();
    const target = this.targets.get(id);
    if (!target || target.ambiguous) throw failure();
    const data = await this.request('session.read', {
      ...(target.runtime ? { target: target.runtime.target } : {}),
      sessionPath: target.path, projectPath: target.projectPath,
    });
    if (this.closed) throw failure();
    const messages = [], activities = [];
    let user = 0, anchor = 'start';
    let slots = {};
    for (const entry of data.entries) {
      if (['user', 'assistant', 'reasoning'].includes(entry.kind)) {
        if (entry.kind === 'user') { anchor = this.id('message', id, ++user, entry.text); slots = {}; }
        const slot = slots[entry.kind] = (slots[entry.kind] ?? 0) + 1;
        const remoteId = entry.kind === 'user' ? this.messageAliases.get(this.id('native-message', id, entry.id)) : undefined;
        // Bind positional history aliases only after Pi consumes queued entries.
        if (remoteId && !entry.running) this.messageAliases.set(anchor, remoteId);
        messages.push({ id: entry.kind === 'user' ? (remoteId ?? this.messageAliases.get(anchor) ?? anchor) : this.id('message', id, anchor, entry.kind, slot),
          role: entry.kind, text: entry.text, turnId: null, streaming: entry.running,
          createdAt: entry.createdAt, updatedAt: entry.createdAt });
      } else {
        activities.push({ id: this.id('activity', id, entry.id), tone: entry.error ? 'error' : entry.kind === 'tool' ? 'tool' : 'info',
          kind: entry.kind === 'tool' ? (entry.running ? 'tool.updated' : 'tool.completed') :
            entry.error ? 'runtime.error' : entry.kind,
          summary: entry.title || entry.kind,
          payload: { detail: entry.text, input: entry.input, running: entry.running,
            ...(entry.kind === 'tool' ? { toolCallId: entry.id,
              data: { toolName: entry.toolName || entry.title?.replace(/^工具\\s*[·:：]?\\s*/, '') } } : {}) },
          turnId: null, createdAt: entry.createdAt });
      }
    }
    const { latestUserMessageAt, hasPendingApprovals, hasPendingUserInput, hasActionableProposedPlan, ...fields } = target.shell;
    const thread = budget({ ...fields, deletedAt: null, messages, activities, proposedPlans: [], checkpoints: [] }, 8 * 1024 * 1024);
    const signature = hash(thread);
    if (this.details.get(id)?.signature !== signature) {
      this.clock.next();
      this.details.set(id, { signature });
    }
    // Replacing a snapshot is safe on replay gaps; we never invent domain events.
    const projected = { ...thread, messages: messages.map(m => m.role === 'reasoning' && !reasoningMessages ? { ...m, role: 'system' } : m) };
    return { snapshotSequence: this.clock.value, thread: projected };
  }
  async dispatch(command, signal) {
    if (this.sendingThreads.has(command.threadId)) throw new Error('session_not_ready');
    this.sendingThreads.add(command.threadId);
    try { return await this.send(command, signal); }
    finally { this.sendingThreads.delete(command.threadId); }
  }
  async send(command, signal) {
    if (command.type !== 'thread.turn.start' || command.sourceProposedPlan || command.message?.context) {
      throw new Error('unsupported_command');
    }
    await this.refresh();
    if (command.bootstrap) {
      const create = command.bootstrap.createThread;
      const project = this.shell.projects.find(p => p.id === create.projectId);
      if (!project || this.targets.has(command.threadId) ||
          !this.models.some(m => m.id === create.modelSelection.model)) throw new Error('invalid_bootstrap');
      if (signal?.aborted) throw new Error('interrupted');
      const result = await this.request('session.send', {
        threadId: command.threadId, projectPath: project.workspaceRoot,
        modelId: create.modelSelection.model,
        commandId: command.commandId, messageId: command.message.messageId,
        text: command.message.text, images: command.images,
      }, { signal });
      if (!result.accepted) throw new Error('submission_failed');
      const anchor = this.id('message', command.threadId, 1, command.message.text.trim() || '请查看附件。');
      this.messageAliases.set(anchor, command.message.messageId);
      this.messageAliases.set(this.id('native-message', command.threadId, command.message.messageId), command.message.messageId);
      await this.refresh();
      this.clock.next();
      void this.poll();
      return { sequence: this.clock.value };
    }
    const target = this.targets.get(command.threadId);
    if (!target || target.ambiguous) throw new Error('stale_target');
    if (command.modelSelection && command.modelSelection.model !== target.shell.modelSelection.model &&
        !this.models.some(m => m.id === command.modelSelection.model)) throw new Error('invalid_model');
    // Bind the optimistic mobile message to the transcript's stable user anchor.
    const before = await this.threadSnapshot(command.threadId, {}, false);
    const text = command.message.text.trim() || '请查看附件。';
    const anchor = this.id('message', command.threadId, before.thread.messages.filter(m => m.role === 'user').length + 1, text);
    if (!target.runtime?.busy) this.messageAliases.set(anchor, command.message.messageId);
    this.messageAliases.set(this.id('native-message', command.threadId, command.message.messageId), command.message.messageId);
    if (signal?.aborted) throw new Error('interrupted');
    const result = await this.request('session.send', {
      ...(target.runtime ? { target: target.runtime.target } : {}),
      sessionPath: target.path, projectPath: target.projectPath,
      commandId: command.commandId, messageId: command.message.messageId,
      text: command.message.text, images: command.images,
      ...(command.modelSelection && command.modelSelection.model !== target.shell.modelSelection.model
        ? { modelId: command.modelSelection.model } : {}),
    }, { signal });
    if (!result.accepted) throw new Error('submission_failed');
    this.clock.next();
    void this.poll();
    return { sequence: this.clock.value };
  }
  async refresh() {
    if (this.closed || this.clock.failed) throw failure();
    if (this.refreshing) return this.refreshing;
    this.refreshing = this.loadCatalog().finally(() => { this.refreshing = null; });
    return this.refreshing;
  }
  async loadCatalog() {
    const catalog = await this.request('workspace.catalog');
    if (this.closed) throw failure();
    const projects = [], threads = [], targets = new Map();
    const runtimes = catalog.runtimes;
    this.models = catalog.models ?? [];
    this.defaultModelId = catalog.defaultModelId || null;
    for (const p of catalog.projects) {
      const projectId = this.id('project', p.path);
      projects.push({ id: projectId, title: p.title || 'Project', workspaceRoot: p.path,
        defaultModelSelection: null, scripts: [], createdAt: epoch, updatedAt: epoch });
      const sessions = new Map(p.sessions.map(s => [s.path, s]));
      for (const r of runtimes.filter(r => r.projectPath === p.path)) if (!sessions.has(r.path)) sessions.set(r.path, { path: r.path, title: r.title, updatedAt: epoch });
      for (const s of sessions.values()) {
        const candidates = runtimes.filter(r => r.projectPath === p.path && r.path === s.path);
        // Ambiguous ownership is unavailable, not permission to select a process.
        const runtime = candidates.length === 1 ? candidates[0] : null;
        const id = s.threadId || this.id('thread', p.path, s.path);
        if (targets.has(id)) throw failure(); // Never accept ambiguous persisted aliases.
        const turn = runtime?.turn;
        const turnId = turn ? this.id('turn', id, turn.id) : null;
        const latestTurn = turn ? { turnId, state: turn.state, requestedAt: turn.startedAt,
          startedAt: turn.startedAt, completedAt: turn.completedAt, assistantMessageId: null } : null;
        const shell = { id, projectId, title: runtime?.title || s.title || 'Session',
          modelSelection: { instanceId: 'pi', model: runtime?.model || 'unknown' },
          runtimeMode: 'full-access', interactionMode: 'default', branch: null, worktreePath: null,
          latestTurn, createdAt: epoch, updatedAt: s.updatedAt, archivedAt: null,
          settledOverride: null, settledAt: null,
          // Mobile V2 ignores wire order and latestUserMessageAt for active rows.
          // Lower lexical arrangement keys sort first; encode descending activity.
          activeOrderKey: `${String(8640000000000000 - (Date.parse(s.updatedAt) || 0)).padStart(16, '0')}-${id}`,
          session: runtime ? { threadId: id, status: runtime.busy ? 'running' : runtime.connected ? 'ready' : 'stopped',
            providerName: 'pi', runtimeMode: 'full-access', activeTurnId: turn?.state === 'running' ? turnId : null,
            lastError: turn?.state === 'error' ? 'Pi task failed' : null, updatedAt: s.updatedAt } : null,
          latestUserMessageAt: s.updatedAt, hasPendingApprovals: false, hasPendingUserInput: runtime?.pendingInput ?? false, hasActionableProposedPlan: false };
        threads.push(shell);
        targets.set(id, { path: s.path, projectPath: p.path, runtime, ambiguous: candidates.length > 1, shell });
      }
    }
    // Clients may preserve wire order or fall back to createdAt when the user
    // timestamp is absent. Publish both the sort key and a deterministic order.
    threads.sort((a, b) => b.latestUserMessageAt.localeCompare(a.latestUserMessageAt) || a.id.localeCompare(b.id));
    const next = budget({ projects, threads });
    const signature = hash(next);
    if (signature !== this.signature) {
      this.clock.next();
      this.signature = signature;
      this.shell = { ...next, snapshotSequence: this.clock.value, updatedAt: new Date().toISOString() };
    }
    this.targets = targets;
    this.activityTurns = catalog.activityTurns ?? [];
    for (const id of this.details.keys()) if (!targets.has(id)) this.details.delete(id);
  }
  watch(kind, input, emit, reject) {
    if (this.closed || this.watchers.size >= 32) { reject(failure()); return () => {}; }
    const watcher = { kind, input, emit, reject };
    this.watchers.add(watcher);
    if (!this.timer) { this.timer = setInterval(() => void this.poll(), this.intervalMs); this.timer.unref(); }
    void this.poll();
    return () => {
      this.watchers.delete(watcher);
      if (!this.watchers.size) { clearInterval(this.timer); this.timer = null; this.details.clear(); }
    };
  }
  async poll() {
    if (this.polling || this.closed) return;
    this.polling = true;
    try {
      await this.refresh();
      const snapshots = new Map();
      for (const w of [...this.watchers]) {
        try {
          if (!this.watchers.has(w)) continue;
          const key = w.kind === 'shell' ? 'shell' : JSON.stringify(w.input);
          if (!snapshots.has(key)) snapshots.set(key, w.kind === 'shell'
            ? { ...this.shell, snapshotSequence: this.clock.value }
            : await this.threadSnapshot(w.input.threadId, w.input, false));
          const snapshot = snapshots.get(key);
          // Ignore watermark-only changes from other threads. A watcher retains
          // only its latest complete snapshot, not an unbounded replay queue.
          const content = hash(w.kind === 'shell' ? [snapshot.projects, snapshot.threads] : snapshot.thread);
          if (content !== w.content && this.watchers.has(w)) {
            w.content = content;
            w.emit([{ kind: 'snapshot', snapshot },
              ...(w.input.requestCompletionMarker ? [{ kind: 'synchronized' }] : [])]);
          }
        } catch { if (this.watchers.has(w)) w.reject(failure()); }
      }
    } catch { for (const w of [...this.watchers]) w.reject(failure()); }
    finally { this.polling = false; }
  }
  close() {
    this.closed = true;
    clearInterval(this.timer);
    for (const w of this.watchers) w.reject(failure());
    this.watchers.clear(); this.details.clear(); this.targets.clear(); this.messageAliases.clear();
  }
}
