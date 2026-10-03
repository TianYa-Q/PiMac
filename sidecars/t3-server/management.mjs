import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
import * as Option from 'effect/Option';
import * as DateTime from 'effect/DateTime';
import * as Fiber from 'effect/Fiber';
import { HttpRouter, HttpServerRequest, HttpServerResponse, HttpServer } from 'effect/unstable/http';
import { AuthStandardClientScopes, AuthAdministrativeScopes } from '@t3tools/contracts';
import { EnvironmentAuth } from './upstream/apps/server/src/auth/EnvironmentAuth.ts';
import { ServerSecretStore } from './upstream/apps/server/src/auth/ServerSecretStore.ts';
import { CloudCliTokenManager } from './upstream/apps/server/src/cloud/CliTokenManager.ts';
import { CloudManagedEndpointRuntime } from './upstream/apps/server/src/cloud/ManagedEndpointRuntime.ts';
import { AgentAwarenessRelay } from './upstream/apps/server/src/relay/AgentAwarenessRelay.ts';
import { ServerConfig } from './upstream/apps/server/src/config.ts';
import { reconcileDesiredCloudLink } from './upstream/apps/server/src/cloud/http.ts';
import { setCliDesiredCloudLink } from './upstream/apps/server/src/cloud/CliState.ts';
import * as CloudConfig from './upstream/apps/server/src/cloud/config.ts';
import { RelayClient } from '@t3tools/shared/relayClient';
import { getNative, httpAllowed } from './native.mjs';
import { loopbackOAuthCallbackAllowed } from './oauth-policy.mjs';
export { oauthAwareCommandReadiness } from './oauth-readiness.mjs';

import { originAllowed } from './origin-policy.mjs';
import { connectionRoute } from './connection-diagnostics.mjs';
import { setModelPreferences } from './model-preferences.mjs';
import { ServerSettingsService } from './upstream/apps/server/src/serverSettings.ts';

import { ProviderRegistry } from './upstream/apps/server/src/provider/Services/ProviderRegistry.ts';

export const NativeHttpPolicy = HttpRouter.middleware(effect => Effect.flatMap(HttpServerRequest.HttpServerRequest, request => {
  const broker = getNative();
  const route = connectionRoute(request.url);
  const fields = { route, method: request.method,
    transport: request.headers['x-forwarded-proto'] === 'https' ? 'https-tunnel' : 'http-local',
    origin: request.headers.origin === undefined ? 'absent' : 'present' };
  const record = (event, extra = {}) => { if (route) broker.connectionDiagnostics.record(event, { ...fields, ...extra }); };
  record('request');
  if (!originAllowed(request.method, request.url, request.headers)) {
    record('denied', { status: 403, reason: 'origin-policy' });
    return Effect.succeed(HttpServerResponse.empty({ status: 403 }));
  }
  const localControl = request.headers['x-pimac-control'] === broker.controlToken && !!broker.controlToken;
  // Global router middleware also wraps the official CLI's separate OAuth
  // listener. Keep /callback off the environment/public server, but let the
  // loopback listener validate the OAuth state and authorization code.
  return loopbackOAuthCallbackAllowed(request) || httpAllowed(request.method, request.url) || (localControl && request.url.startsWith('/api/connect/'))
    ? effect.pipe(Effect.tap(response => Effect.sync(() => record('response', { status: response.status }))))
    : Effect.sync(() => { record('denied', { status: 404, reason: 'http-policy' }); return HttpServerResponse.empty({ status: 404 }); });
}), { global: true });

export const NativeManagementLayer = Layer.effectDiscard(Effect.gen(function* () {
  const broker = getNative();
  const auth = yield* EnvironmentAuth, secrets = yield* ServerSecretStore, tokens = yield* CloudCliTokenManager;
  const runtime = yield* CloudManagedEndpointRuntime, awareness = yield* AgentAwarenessRelay;
  const server = yield* HttpServer.HttpServer;
  const relayClient = yield* RelayClient;
  const settings = yield* ServerSettingsService;
  const providers = yield* ProviderRegistry;
  const controlContext = yield* Effect.context();
  const localURL = `http://127.0.0.1:${server.address.port}`;
  const originalApply = runtime.applyConfig;
  runtime.applyConfig = value => originalApply(value).pipe(Effect.tap(status => Effect.sync(() => {
    broker.tunnelHealth.config(status);
    broker.connectionDiagnostics.record('tunnel-config', {
      reason: status.status + ('failure' in status ? ':' + status.failure : ''),
    });
  })));
  let adminToken, loginFiber, loginPending = false, busy = false, deviceCount = null, tunnelURL = '';
  const run = effect => Effect.runPromise(Effect.provide(effect, controlContext));
  const readSecret = name => secrets.get(name).pipe(Effect.map(value => Option.isSome(value) ? new TextDecoder().decode(value.value) : ''));
  const localRequest = async (pathname, method = 'GET', body) => {
    if (!adminToken) adminToken = (await run(auth.issueSession({ subject: 'pimac-internal-administration', scopes: AuthAdministrativeScopes }))).token;
    const result = await fetch(localURL + pathname, { method, redirect: 'error', signal: AbortSignal.timeout(45000),
      headers: { authorization: `Bearer ${adminToken}`, 'x-pimac-control': broker.controlToken,
        ...(body ? { 'content-type': 'application/json' } : {}) }, ...(body ? { body: JSON.stringify(body) } : {}) });
    if (!result.ok) throw new Error('Official T3 control request failed'); return result.json();
  };
  const status = async () => {
    const [account, credential, publishing, authorized] = await Promise.all([
      run(readSecret(CloudConfig.CLOUD_LINKED_USER_ID)), run(readSecret(CloudConfig.RELAY_ENVIRONMENT_CREDENTIAL_SECRET)),
      run(CloudConfig.readAgentActivityPublishingActive(secrets)), run(tokens.hasCredential).catch(() => false),
    ]);
    return { available: true, networkDiagnostic: [broker.networkDiagnostic, broker.connectionDiagnostics.summary].filter(Boolean).join('\n'), authorized, linked: !!credential, enabled: publishing, account, loginPending, busy,
      deviceCount, message: broker.message, tunnelStatus: broker.tunnelHealth.status, tunnelURL, backend: 't3-server', ...broker.diagnostics };
  };
  const refreshDevices = async () => {
    const token = await run(tokens.getExisting); if (Option.isNone(token)) throw new Error('Not authorized');
    const headers = { authorization: `Bearer ${token.value.accessToken}` };
    const devices = await fetch('https://relay.t3.codes/v2/client/devices', { headers, redirect: 'error', signal: AbortSignal.timeout(12000) });
    if (!devices.ok) throw new Error('Device query failed'); const body = await devices.json();
    deviceCount = body.devices.filter(d => d.platform === 'ios' && d.notifications.enabled).length;
    const environments = await fetch('https://relay.t3.codes/v1/environments', { headers, redirect: 'error', signal: AbortSignal.timeout(12000) });
    if (environments.ok) {
      const list = await environments.json();
      const environment = list.environments?.find(e => e.environmentId === broker.environmentId);
      tunnelURL = environment?.endpoint?.httpBaseUrl ?? '';
    }
  };
  const link = Effect.gen(function* () {
    if ((yield* relayClient.resolve).status !== 'available') {
      broker.message = '正在通过官方 T3 安装器校验并安装 cloudflared…';
      yield* relayClient.install;
    }
    yield* setCliDesiredCloudLink(true, 'managed');
    yield* reconcileDesiredCloudLink(localURL);
    yield* secrets.set(CloudConfig.PUBLISH_AGENT_ACTIVITY_SECRET, new TextEncoder().encode('true'));
    yield* awareness.requestCatchUp();
    broker.message = '官方 T3 Server 已绑定账号并请求托管 Cloudflare Tunnel；连接状态及实机通知仍需验收。';
  });
  const login = async reauthorize => {
    if (busy || loginPending) throw new Error('Busy');
    const previousAccount = await run(readSecret(CloudConfig.CLOUD_LINKED_USER_ID));
    const previousToken = await run(tokens.getExisting).catch(() => Option.none());
    if (reauthorize) await run(tokens.clear);
    let accountConfirmed = false, failed = false;
    let stage = '授权网页或本机回调';
    busy = true; loginPending = true; broker.browserURL = null;
    broker.message = '正在启动官方授权；请在浏览器完成登录。';
    let resolveURL, rejectURL;
    const browser = new Promise((resolve, reject) => { resolveURL = resolve; rejectURL = reject; });
    const timeout = setTimeout(() => {
      failed = true;
      broker.message = '授权网页未能启动，请检查网络和本机 34338 端口后重试。';
      rejectURL(new Error('Authorization did not open'));
      if (loginFiber) void run(Fiber.interrupt(loginFiber));
    }, 15000);
    broker.onBrowser = url => {
      busy = false; clearTimeout(timeout);
      broker.message = '等待浏览器授权回调；请勿关闭 Pi Mac，可取消后重新登录。';
      resolveURL({ url });
    };
    loginFiber = Effect.runFork(tokens.get.pipe(
      Effect.flatMap(result => result._tag === 'Authorized' ? Effect.promise(async () => {
        if (previousAccount) {
          const response = await fetch('https://clerk.t3.codes/oauth/userinfo', {
            headers: { authorization: `Bearer ${result.token.accessToken}` }, redirect: 'error', signal: AbortSignal.timeout(12000) });
          if (!response.ok || (await response.json()).sub !== previousAccount) throw new Error('Account mismatch');
        }
        accountConfirmed = true;
        stage = 'Cloudflare 安装或环境绑定';
        broker.message = '账号授权已完成，正在绑定环境与配置隧道…';
      }).pipe(Effect.andThen(link)) : Effect.fail(new Error('Interactive authorization required'))),
      Effect.tap(() => Effect.promise(async () => { try { await refreshDevices(); } catch {} })),
      Effect.catchCause(() => Effect.sync(() => {
        failed = true;
        broker.message = `${stage}未完成。${accountConfirmed ? '账号凭据已保留，可点击重试绑定。' : '请检查网络、本机 34338 端口，并使用已绑定的同一账号。'}`;
        rejectURL(new Error('Authorization failed'));
      })),
      Effect.ensuring(Effect.gen(function* () {
        if (reauthorize && !accountConfirmed) {
          if (Option.isSome(previousToken)) yield* tokens.store(previousToken.value);
          else yield* tokens.clear;
        }
        clearTimeout(timeout); loginPending = false; busy = false; broker.onBrowser = null;
      })), 
      Effect.provide(controlContext),
    ));
    // Existing credentials can complete without opening a browser.
    const completed = Effect.runPromise(Fiber.await(loginFiber)).then(() => {
      if (failed) throw new Error('Authorization failed');
      return status();
    });
    return Promise.race([browser, completed]);
  };
  broker.management = {
    localURL, status,
    async modelCatalog() {
      const snapshots = await run(providers.refreshInstance('pi'));
      return { catalogs: JSON.stringify(Object.fromEntries(snapshots.map(p => [p.instanceId, p.models]))) };
    },
    async modelPreferences(value) {
      setModelPreferences(value);
      const model = value.defaultModel && !value.hiddenModels.includes(value.defaultModel) ? value.defaultModel : null;
      await run(settings.updateSettings({ defaultModelSelection: model ? { instanceId: 'pi', model } : null }));
      await run(providers.refreshInstance('pi'));
      return { ok: true };
    },
    async desktopSession() {
      const session = await run(auth.issueSession({ subject: 'pimac-desktop', scopes: AuthStandardClientScopes }));
      return { token: session.token };
    },
    async pairing(input) { const result = await run(auth.issuePairingCredential({ label: input.label, scopes: AuthStandardClientScopes }));
      return { id: result.id, credential: result.credential, expiresAt: DateTime.formatIso(result.expiresAt) }; },
    async clients() { const sessions = await run(auth.listSessions()); return sessions.filter(s => !['pimac-internal-administration', 'pimac-desktop'].includes(s.subject)).map(s => ({
      ...s, issuedAt: DateTime.formatIso(s.issuedAt), expiresAt: DateTime.formatIso(s.expiresAt),
      lastConnectedAt: s.lastConnectedAt ? DateTime.formatIso(s.lastConnectedAt) : null })); },
    async pairingLinks() { return (await run(auth.listPairingLinks())).map(link => ({ id: link.id })); },
    async revokeClient(id) { return { revoked: await run(auth.revokeSession(id)) }; },
    async revokePairing(id) { return { revoked: await run(auth.revokePairingLink(id)) }; },
    async control(operation) {
      if (operation === 'login' || operation === 'reauthorize') return login(operation === 'reauthorize');
      if (operation === 'cancel-login') { if (loginFiber) await run(Fiber.interrupt(loginFiber)); return status(); }
      if (busy || loginPending) throw new Error('Busy'); busy = true;
      try {
        if (operation === 'retry-link') await run(link);
        else if (operation === 'refresh-devices') await refreshDevices();
        else if (operation === 'enable' || operation === 'disable') {
          await localRequest('/api/connect/preferences', 'POST', { publishAgentActivity: operation === 'enable' });
        } else if (operation === 'logout') {
          // Unlink must succeed before removing credentials. Failure disables
          // publishing and leaves official state available for a revocation retry.
          await run(secrets.set(CloudConfig.PUBLISH_AGENT_ACTIVITY_SECRET, new TextEncoder().encode('false')));
          await localRequest('/api/connect/unlink', 'POST'); await run(tokens.clear); tunnelURL = ''; deviceCount = null;
          broker.message = '已通过官方 T3 Server 撤销环境绑定及托管隧道。';
        } else throw new Error('Invalid operation');
        return status();
      } catch { broker.message = '官方 T3 操作未确认成功；不应视为绑定、投递或撤销已完成。'; throw new Error('T3 control failed'); }
      finally { busy = false; }
    },
  };
  broker.onManagementReady?.(broker.management);
  yield* Effect.addFinalizer(() => Effect.sync(() => { if (loginFiber) Effect.runFork(Fiber.interrupt(loginFiber)); }));
}));
