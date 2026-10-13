// 只保留会话绑定元数据；额度查询不能用全局 auth/default 推断线程账户。
export function createPiAccountSelections() {
  const selections = new Map();
  return {
    record(threadId, event) {
      if (event?.method !== 'setStatus' || event.statusKey !== 'account-usage-gui') return;
      if (typeof threadId !== 'string' || typeof event.statusText !== 'string' ||
          Buffer.byteLength(event.statusText) > 1048576) return;
      if (!event.statusText) { selections.delete(threadId); return; }
      let payload;
      try { payload = JSON.parse(event.statusText); } catch { return; }
      const provider = payload?.provider ?? 'openai-codex';
      if (![1, 2].includes(payload?.version) || !['openai', 'openai-codex', 'antigravity'].includes(provider) ||
          !Array.isArray(payload.accounts) || !Number.isFinite(payload.updatedAt) || payload.updatedAt < 0 ||
          (payload.activeAccount !== undefined && typeof payload.activeAccount !== 'string')) return;
      const previous = selections.get(threadId);
      if (previous?.provider === provider && previous.updatedAt > payload.updatedAt) return;
      selections.set(threadId, { version: payload.version, provider, updatedAt: payload.updatedAt,
        ...(payload.activeAccount ? { activeAccount: payload.activeAccount } : {}),
        supportsAccountSwitch: payload.version === 1 || payload.supportsAccountSwitch === true,
        managesSelectedAuth: payload.version === 1 ? !!payload.activeAccount : payload.managesSelectedAuth === true,
        geminiIsActive: payload.gemini?.isActive === true });
    },
    read(threadId, provider) {
      const value = selections.get(threadId);
      return value?.provider === provider ? { ...value } : undefined;
    },
    close() { selections.clear(); },
  };
}
