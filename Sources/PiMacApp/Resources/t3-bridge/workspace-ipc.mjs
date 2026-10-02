import { randomUUID } from 'node:crypto';

// Private sidecar -> Swift reads. Caller IDs and file paths are never forwarded
// from T3 requests. Expected paths come exclusively from the desktop catalog.
export function createWorkspaceIPC(send, { timeoutMs = 5000, maxPending = 16 } = {}) {
  const pending = new Map();
  let closed = false;
  return {
    request(method, fields = {}, { signal } = {}) {
      if (signal?.aborted) return Promise.reject(new Error('Workspace operation interrupted'));
      if (closed || pending.size >= maxPending) return Promise.reject(new Error('Workspace unavailable'));
      if (!['workspace.catalog', 'session.read', 'session.send'].includes(method)) return Promise.reject(new Error('Unsupported operation'));
      const id = randomUUID();
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => { const entry = pending.get(id); pending.delete(id); entry?.reject(new Error('Workspace operation timed out')); }, method === 'session.send' ? 30000 : timeoutMs);
        const interrupt = () => {
          if (method !== 'session.send' || !pending.has(id)) return;
          try { send({ id: randomUUID(), method: 'session.cancelSend', commandId: fields.commandId }); } catch { /* Outcome remains unknown. */ }
          clearTimeout(timer); pending.delete(id); cleanup();
          reject(new Error('Workspace operation interrupted; check outcome'));
        };
        signal?.addEventListener('abort', interrupt, { once: true });
        const cleanup = () => signal?.removeEventListener('abort', interrupt);
        pending.set(id, { resolve: value => { cleanup(); resolve(value); }, reject: error => { cleanup(); reject(error); }, timer });
        try { send({ ...fields, id, method }); }
        catch { cleanup(); clearTimeout(timer); pending.delete(id); reject(new Error('Workspace unavailable')); }
      });
    },
    receive(message) {
      const entry = pending.get(message.id);
      if (!entry) return;
      pending.delete(message.id);
      clearTimeout(entry.timer);
      if (message.error || !message.result) {
        const error = new Error('Workspace operation rejected');
        if (['sending_disabled', 'submission_failed', 'invalid_send'].includes(message.error?.code)) error.code = message.error.code;
        entry.reject(error);
      } else entry.resolve(message.result);
    },
    close() {
      closed = true;
      for (const entry of pending.values()) {
        clearTimeout(entry.timer);
        entry.reject(new Error('Workspace closed'));
      }
      pending.clear();
    },
  };
}
