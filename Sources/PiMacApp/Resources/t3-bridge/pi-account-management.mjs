// Host quota transport. Session bindings remain owned by official Pi.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash } from 'node:crypto';
import { boundedJSON, discardBody } from './bounded-json.mjs';

const providers = new Set(['openai', 'openai-codex']);
const MAX_BYTES = 256 * 1024;
function privateJSON(file) {
  let fd;
  try {
    fd = fs.openSync(file, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW);
    const stat = fs.fstatSync(fd);
    if (!stat.isFile() || stat.uid !== process.getuid() || (stat.mode & 0o077) || stat.size > MAX_BYTES) throw new Error('unsafe');
    return JSON.parse(fs.readFileSync(fd, 'utf8'));
  } catch (error) {
    if (error.code === 'ENOENT') return {};
    throw new Error('账户文件不可读取；请检查权限或格式。');
  } finally { if (fd !== undefined) fs.closeSync(fd); }
}
function accountID(credential) {
  if (!credential || typeof credential !== 'object') return undefined;
  if (typeof credential.accountId === 'string' && credential.accountId) return credential.accountId;
  try {
    const claims = JSON.parse(Buffer.from(credential.access.split('.')[1], 'base64url').toString());
    const id = claims['https://api.openai.com/auth']?.chatgpt_account_id;
    return typeof id === 'string' && id ? id : undefined;
  } catch { return undefined; }
}
function sameAccount(left, right) {
  const leftID = accountID(left), rightID = accountID(right);
  if (leftID && rightID) return leftID === rightID;
  // Older credentials may lack identity metadata; exact token equality is only
  // a fallback, never a reason to treat two different known IDs as equivalent.
  return typeof left?.access === 'string' && left.access.length > 0 && left.access === right?.access;
}
function window(value) {
  if (!value || !Number.isFinite(value.used_percent)) return undefined;
  return { remainingPercent: 100 - Math.max(0, Math.min(100, value.used_percent)),
    ...(Number.isFinite(value.reset_at) && value.reset_at > 0 ? { resetAt: value.reset_at } : {}),
    ...(Number.isFinite(value.limit_window_seconds) && value.limit_window_seconds > 0 ? { windowSeconds: value.limit_window_seconds } : {}) };
}
export function createPiAccountManagement({ agentDirectory = process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), '.pi', 'agent'), fetchImpl = fetch, now = Date.now, resolveCredential = async (_provider, _name, credential, _signal, _force) => credential } = {}) {
  const cache = new Map(), pending = new Map(), successfulAccounts = new Map();
  const controller = new AbortController();
  // Private identity digests never cross IPC. Names alone cannot identify a login.
  const identity = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
  async function queryResetCredits(credential, id, signal) {
    // Supplementary, read-only metadata: unsupported plans or failures must not
    // discard valid usage windows. Only allowlisted fields cross IPC.
    try {
      const response = await fetchImpl('https://chatgpt.com/backend-api/wham/rate-limit-reset-credits', {
        headers: { authorization: `Bearer ${credential.access}`, 'chatgpt-account-id': id },
        redirect: 'error', signal,
      });
      if (!response.ok) { discardBody(response); return undefined; }
      const body = await boundedJSON(response, { maxBytes: MAX_BYTES, signal });
      const rawCount = body?.available_count;
      const count = typeof rawCount === 'number' ? rawCount
        : typeof rawCount === 'string' && rawCount.trim() ? Number(rawCount) : NaN;
      if (!Number.isFinite(count) || count < 0) return undefined;
      const credits = (Array.isArray(body.credits) ? body.credits : []).flatMap(credit => {
        if (credit?.status !== 'available') return [];
        const expiry = typeof credit.expires_at === 'string' ? Date.parse(credit.expires_at) : NaN;
        // Codex timestamps use seconds.
        return [Number.isFinite(expiry) ? { expiresAt: expiry / 1000 } : {}];
      });
      return { availableCount: Math.floor(count), credits };
    } catch { return undefined; }
  }
  async function query(provider) {
    const prefix = provider === 'openai' ? 'openai-chatgpt' : 'codex';
    const auth = privateJSON(path.join(agentDirectory, 'auth.json'));
    const store = privateJSON(path.join(agentDirectory, `${prefix}-accounts.json`));
    const settings = privateJSON(path.join(agentDirectory, `${prefix}-account-usage.json`));
    const accounts = Object.entries(store.accounts ?? {}).filter(([name]) => /^[A-Za-z0-9._-]{1,64}$/.test(name)).slice(0, 64);
    const native = auth[provider];
    // Do not claim this is the auth bound to any existing thread. Native Pi and
    // extension-managed session bindings may differ from the global auth file.
    if (native?.type === 'oauth') {
      const index = accounts.findIndex(([, credential]) => sameAccount(credential, native));
      if (index < 0) accounts.unshift(['Pi 已保存授权', native]);
      else if (Number.isFinite(native.expires) && (!Number.isFinite(accounts[index][1]?.expires) || native.expires > accounts[index][1].expires)) {
        // Use the fresher grant for this read only; preserve the user's alias
        // and never rewrite either the native auth or the extension store.
        accounts[index] = [accounts[index][0], native];
      }
    }
    const rows = [];
    const previousAccounts = successfulAccounts.get(provider) ?? new Map();
    const nextAccounts = new Map();
    for (let offset = 0; offset < accounts.length; offset += 2) await Promise.all(accounts.slice(offset, offset + 2).map(async ([name, storedCredential]) => {
      controller.signal.throwIfAborted();
      const row = { name, hidden: settings.hiddenAccounts?.includes(name) === true, capturedAt: now() };
      // 隐藏账户不查询，也不向桌面/iOS 的额度接口返回占位或旧缓存。
      if (row.hidden) return;
      const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(15000)]);
      let credential = storedCredential;
      try { credential = await resolveCredential(provider, name, storedCredential, signal, false); }
      catch { row.error = '授权刷新失败，请重新登录或稍后重试。'; }
      const id = accountID(credential);
      if (row.error) { /* 不使用刷新失败的旧凭据继续查询。 */ }
      else if (!id || typeof credential.access !== 'string') row.error = '授权缺少 ChatGPT account ID，无法查询额度。';
      else if (!Number.isFinite(credential.expires) || credential.expires <= now()) row.error = '授权已过期，请在 PiMac 重新登录托管账户，或通过 Pi 更新原生授权。';
      else {
        try {
          signal.throwIfAborted();
          let response;
          for (let attempt = 0; attempt < 2; attempt++) {
            response = await fetchImpl('https://chatgpt.com/backend-api/wham/usage', {
              headers: { authorization: `Bearer ${credential.access}`, 'chatgpt-account-id': id },
              redirect: 'error', signal,
            });
            if (response.status !== 401 || attempt > 0) break;
            discardBody(response);
            const refreshed = await resolveCredential(provider, name, credential, signal, true);
            if (accountID(refreshed) !== id) throw new Error('identity changed');
            if (refreshed.access === credential.access && refreshed.expires === credential.expires) break;
            credential = refreshed;
          }
          if (!response?.ok) { if (response) discardBody(response); throw new Error('http'); }
          const body = await boundedJSON(response, { maxBytes: MAX_BYTES, signal });
          row.primary = window(body.rate_limit?.primary_window);
          row.secondary = window(body.rate_limit?.secondary_window);
          if (!row.primary && !row.secondary) throw new Error('shape');
          const resetCredits = await queryResetCredits(credential, id, signal);
          if (resetCredits) row.resetCredits = resetCredits;
        } catch {
          // No response bodies, tokens, URLs or arbitrary error strings cross IPC.
          row.error = '额度查询失败，请检查网络和账户授权。';
        }
      }
      row.capturedAt = now();
      const key = identity([provider, name, id || credential?.access]);
      if (row.error) {
        const previous = previousAccounts.get(key);
        if (previous) {
          row.primary = previous.primary;
          row.secondary = previous.secondary;
          row.resetCredits = previous.resetCredits;
          row.capturedAt = previous.capturedAt;
          nextAccounts.set(key, previous);
        }
      } else if (row.primary || row.secondary) {
        nextAccounts.set(key, { ...row });
      }
      rows.push(row);
    }));
    successfulAccounts.set(provider, nextAccounts);
    return { version: 2, provider, supportsAccountSwitch: false, managesSelectedAuth: false,
      updatedAt: now(), accounts: rows, source: 'host-query',
      message: rows.length ? '只读额度查询；不代表当前线程的授权绑定。' : '未找到可查询的 OAuth 账户；API key 不提供订阅额度。' };
  }
  // 可见性可能在缓存 TTL 或网络查询期间变化，每次出站按最新设置过滤。
  function visibleSnapshot(value, provider) {
    const prefix = provider === 'openai' ? 'openai-chatgpt' : 'codex';
    const settings = privateJSON(path.join(agentDirectory, `${prefix}-account-usage.json`));
    if (settings.hiddenAccounts !== undefined && (!Array.isArray(settings.hiddenAccounts) ||
        settings.hiddenAccounts.some(name => typeof name !== 'string'))) {
      throw new Error('账户显示设置格式无效。');
    }
    const hidden = new Set(settings.hiddenAccounts ?? []);
    return { ...value, accounts: value.accounts.filter(row => !row.hidden && !hidden.has(row.name)) };
  }
  return {
    async accountStatus({ provider, force = false } = {}) {
      if (!providers.has(provider)) throw new Error('Unsupported account provider');
      if (controller.signal.aborted) throw new Error('Closed');
      if (pending.has(provider)) return pending.get(provider);
      const previous = cache.get(provider);
      if (!force && previous && now() - previous.updatedAt < 60000) return { ...visibleSnapshot(previous, provider), cached: true };
      const task = query(provider).then(value => { cache.set(provider, value); return { ...visibleSnapshot(value, provider), cached: false }; }).finally(() => pending.delete(provider));
      pending.set(provider, task); return task;
    },
    close() { controller.abort(); cache.clear(); successfulAccounts.clear(); },
  };
}
