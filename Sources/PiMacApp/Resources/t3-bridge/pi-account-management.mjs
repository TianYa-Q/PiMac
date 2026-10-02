// Read-only host capability. Official Pi remains the sole auth/session writer.
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const providers = new Set(['openai', 'openai-codex', 'antigravity']);
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
async function boundedJSON(response) {
  const chunks = []; let size = 0;
  for await (const chunk of response.body) {
    size += chunk.length;
    if (size > MAX_BYTES) throw new Error('oversize');
    chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}
export function createPiAccountManagement({ agentDirectory = process.env.PI_CODING_AGENT_DIR || path.join(os.homedir(), '.pi', 'agent'), fetchImpl = fetch, now = Date.now } = {}) {
  const cache = new Map(), pending = new Map();
  const controller = new AbortController();
  async function queryGemini(auth, provider) {
    const credential = auth.antigravity;
    const status = { kind: 'unconfigured', isActive: provider === 'antigravity', quotas: [] };
    if (credential?.type !== 'oauth') return status;
    status.kind = 'failed';
    if (typeof credential.access !== 'string' || !credential.access) {
      return { ...status, error: 'Antigravity 授权无效，请通过 Pi 重新登录。' };
    }
    if (!Number.isFinite(credential.expires) || credential.expires <= now()) {
      return { ...status, error: 'Antigravity 授权已过期，请通过 Pi 登录或刷新授权。' };
    }
    const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(12000)]);
    // Fixed Google origins only; never forward credentials to redirects or a
    // project/server-provided URL. This capability never refreshes or writes auth.
    async function request(method, payload) {
      for (const endpoint of ['https://cloudcode-pa.googleapis.com', 'https://daily-cloudcode-pa.sandbox.googleapis.com']) {
        try {
          const response = await fetchImpl(endpoint + '/v1internal:' + method, {
          method: 'POST', redirect: 'error', signal,
          headers: { authorization: `Bearer ${credential.access}`, 'content-type': 'application/json',
            'user-agent': 'antigravity/cli/1.1.23 (aidev_client; os_type=linux; arch=amd64; cl=974125021; auth_method=consumer)' },
          body: JSON.stringify(payload),
          });
          if (!response.ok) { await response.body?.cancel(); continue; }
          return await boundedJSON(response);
        } catch {
          if (signal.aborted) break;
        }
      }
      throw new Error('request');
    }
    // Paid accounts expose both short and weekly windows here. Model quotas
    // alone do not carry the weekly bucket. Free accounts may return 403.
    try {
      const summary = await request('retrieveUserQuotaSummary', {});
      const unique = new Map();
      for (const group of Array.isArray(summary.groups) ? summary.groups : []) {
        if (!/gemini/i.test(group?.displayName) || !Array.isArray(group.buckets)) continue;
        for (const bucket of group.buckets) {
          if (!Number.isFinite(bucket?.remainingFraction)) continue;
          const resetAt = typeof bucket.resetTime === 'string' ? Date.parse(bucket.resetTime) : NaN;
          const window = [bucket.window, bucket.displayName].filter(value => typeof value === 'string').join(' ').trim();
          const row = {
            remainingPercent: Math.round(Math.max(0, Math.min(1, bucket.remainingFraction)) * 1000) / 10,
            ...(Number.isFinite(resetAt) ? { resetAt } : {}),
            ...(window ? { window } : {}),
          };
          unique.set(JSON.stringify(row), row);
        }
      }
      if (unique.size) {
        const rank = row => /5\s*h|five.?hour/i.test(row.window ?? '') ? 0 : /7\s*d|week/i.test(row.window ?? '') ? 1 : 2;
        return { ...status, kind: 'loaded', quotas: [...unique.values()].sort((a, b) => rank(a) - rank(b)).slice(0, 64) };
      }
    } catch { /* Summary is optional; retain per-model quota fallback. */ }
    try {
        const body = await request('fetchAvailableModels', typeof credential.projectId === 'string' ? { project: credential.projectId } : {});
        if (!body.models || typeof body.models !== 'object' || Array.isArray(body.models)) throw new Error('shape');
        const unique = new Map();
        for (const [id, model] of Object.entries(body.models)) {
          const quota = model?.quotaInfo;
          if (!/gemini/i.test(id) || model?.isInternal || !Number.isFinite(quota?.remainingFraction)) continue;
          const remainingPercent = Math.round(Math.max(0, Math.min(1, quota.remainingFraction)) * 1000) / 10;
          const resetAt = typeof quota.resetTime === 'string' ? Date.parse(quota.resetTime) : NaN;
          const row = { remainingPercent, ...(Number.isFinite(resetAt) ? { resetAt } : {}) };
          unique.set(JSON.stringify(row), row);
        }
        if (!unique.size) throw new Error('shape');
        return { ...status, kind: 'loaded', quotas: [...unique.values()].slice(0, 64) };
    } catch { /* No provider error bodies cross IPC. */ }
    return { ...status, error: 'Antigravity 额度查询失败，请检查网络和账户授权。' };
  }
  async function query(provider) {
    const prefix = provider === 'openai' ? 'openai-chatgpt' : 'codex';
    const auth = privateJSON(path.join(agentDirectory, 'auth.json'));
    const geminiTask = queryGemini(auth, provider);
    if (provider === 'antigravity') return { version: 2, provider, accounts: [], gemini: await geminiTask,
      supportsAccountSwitch: false, managesSelectedAuth: false, updatedAt: now(), source: 'host-query',
      message: (await geminiTask).kind === 'unconfigured' ? '未找到 Antigravity OAuth 授权，请通过 Pi 登录。' : '只读额度查询；不代表当前线程的授权绑定。' };
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
    const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(12000)]);
    for (const [name, credential] of accounts) {
      controller.signal.throwIfAborted();
      const row = { name, hidden: settings.hiddenAccounts?.includes(name) === true, capturedAt: now() };
      if (row.hidden) { rows.push(row); continue; }
      const id = accountID(credential);
      if (!id || typeof credential.access !== 'string') row.error = '授权缺少 ChatGPT account ID，无法查询额度。';
      else if (!Number.isFinite(credential.expires) || credential.expires <= now()) row.error = '授权已过期，请通过 Pi 登录或账户扩展刷新授权。';
      else {
        try {
          signal.throwIfAborted();
          const response = await fetchImpl('https://chatgpt.com/backend-api/wham/usage', {
            headers: { authorization: `Bearer ${credential.access}`, 'chatgpt-account-id': id },
            redirect: 'error', signal,
          });
          if (!response.ok) { await response.body?.cancel(); throw new Error('http'); }
          const body = await boundedJSON(response);
          row.primary = window(body.rate_limit?.primary_window);
          row.secondary = window(body.rate_limit?.secondary_window);
          if (!row.primary && !row.secondary) throw new Error('shape');
        } catch {
          // No response bodies, tokens, URLs or arbitrary error strings cross IPC.
          row.error = '额度查询失败，请检查网络和账户授权。';
        }
      }
      row.capturedAt = now(); rows.push(row);
    }
    return { version: 2, provider, supportsAccountSwitch: false, managesSelectedAuth: false,
      updatedAt: now(), accounts: rows, gemini: await geminiTask, source: 'host-query',
      message: rows.length ? '只读额度查询；不代表当前线程的授权绑定。' : '未找到可查询的 OAuth 账户；API key 不提供订阅额度。' };
  }
  return {
    async accountStatus({ provider, force = false } = {}) {
      if (!providers.has(provider)) throw new Error('Unsupported account provider');
      if (controller.signal.aborted) throw new Error('Closed');
      if (pending.has(provider)) return pending.get(provider);
      const previous = cache.get(provider);
      if (!force && previous && now() - previous.updatedAt < 60000) return { ...previous, cached: true };
      const task = query(provider).then(value => { cache.set(provider, value); return { ...value, cached: false }; }).finally(() => pending.delete(provider));
      pending.set(provider, task); return task;
    },
    close() { controller.abort(); cache.clear(); },
  };
}
