// Read-only extension quota snapshots. Never retain auth tokens or dialog payloads.
import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';
const snapshots = new Map();
const shared = new Map();
let cachePath;

export function configureAccountStatuses(directory) {
  clearAccountStatuses();
  const file = path.join(directory, 'account-quota-cache.json');
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) || stat.size > 512 * 1024) return;
    const document = JSON.parse(fs.readFileSync(fd, 'utf8'));
    if (document.version !== 1 || !Array.isArray(document.snapshots)) return;
    for (const status of document.snapshots) {
      // Reapply the allowlist when loading, not just when writing.
      recordAccountStatus('@cache', { type: 'extension_ui_request', method: 'setStatus',
        statusKey: 'account-usage-gui', statusText: JSON.stringify(status) });
    }
    snapshots.delete('@cache');
  } catch { /* Missing/corrupt cache must never prevent Server startup. */ }
  finally { if (fd !== undefined) fs.closeSync(fd); cachePath = file; }
}

function persistShared() {
  if (!cachePath) return;
  const temporary = cachePath + '.' + randomUUID() + '.tmp';
  try {
    fs.writeFileSync(temporary, JSON.stringify({ version: 1, snapshots: [...shared.values()] }),
      { mode: 0o600, flag: 'wx' });
    fs.renameSync(temporary, cachePath);
  } catch { /* A quota cache failure must not affect a task. */ }
  finally { try { fs.unlinkSync(temporary); } catch {} }
}
export function recordAccountStatus(threadId, event) {
  if (event.type !== 'extension_ui_request' || event.method !== 'setStatus' || event.statusKey !== 'account-usage-gui') return;
  try {
    const payload = JSON.parse(event.statusText);
    if (![1, 2].includes(payload.version) || !Array.isArray(payload.accounts)) return;
    // Explicit allowlist: an extension must not accidentally expose credentials.
    const pick = (value, keys) => Object.fromEntries(keys.filter(key => value?.[key] !== undefined).map(key => [key, value[key]]));
    const window = value => value ? pick(value, ['remainingPercent', 'resetAt', 'windowSeconds']) : undefined;
    const safe = pick(payload, ['version', 'provider', 'activeAccount', 'defaultAccount', 'updatedAt']);
    safe.supportsAccountSwitch = false;
    safe.managesSelectedAuth = payload.managesSelectedAuth === true;
    safe.accounts = payload.accounts.map(account => ({ ...pick(account, ['name', 'hidden', 'capturedAt']),
      primary: window(account.primary), secondary: window(account.secondary),
      ...(account.error ? { error: '账户额度查询失败，请检查账户授权。' } : {}) }));
    if (payload.gemini) safe.gemini = { ...pick(payload.gemini, ['kind', 'isActive']),
      quotas: (payload.gemini.quotas ?? []).map(q => pick(q, ['remainingPercent', 'resetAt', 'window'])),
      ...(payload.gemini.error ? { error: 'Gemini 额度查询失败。' } : {}) };
    snapshots.set(threadId, safe);
    const provider = safe.provider ?? 'openai-codex';
    const previous = shared.get(provider);
    if (!previous || (safe.updatedAt ?? 0) >= (previous.updatedAt ?? 0)) {
      // Persist quota data only, never the active auth binding of a task.
      const cached = { ...safe, activeAccount: undefined, managesSelectedAuth: false };
      shared.set(provider, cached);
      if (JSON.stringify(previous) !== JSON.stringify(cached)) persistShared();
    }
  } catch { /* Invalid extension status does not break a running turn. */ }
}
export function accountStatus(threadId, provider) {
  const selected = snapshots.get(threadId);
  const latest = shared.get(selected?.provider ?? provider)
    ?? (!provider ? [...shared.values()].sort((a, b) => (b.updatedAt ?? 0) - (a.updatedAt ?? 0))[0] : undefined);
  if (!selected) return latest ? { ...latest, activeAccount: undefined, managesSelectedAuth: false } : null;
  // Shared quotas can refresh on the discovery runtime while a thread is idle.
  // Only merge the same provider; retain the thread's own auth selection.
  return latest && latest.provider === selected.provider && latest.updatedAt > selected.updatedAt
    ? { ...latest, activeAccount: selected.activeAccount, managesSelectedAuth: selected.managesSelectedAuth } : selected;
}
export function clearAccountStatuses() { snapshots.clear(); shared.clear(); cachePath = undefined; }
