import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID, createHash } from 'node:crypto';
import { generateKeyPair, exportJWK, SignJWT } from 'jose';
import * as DateTime from 'effect/DateTime';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';
import WebSocket from 'ws';
import http from 'node:http';
import { originAllowed } from '../origin-policy.mjs';
import { call, readStream } from '../generated/client.mjs';

test('Tunnel HTTPS Origin uses the forwarded scheme without relaxing cross-origin policy', () => {
  const headers = { host: 'tunnel.example.test', origin: 'https://tunnel.example.test',
    upgrade: 'websocket', 'x-forwarded-proto': 'https' };
  assert.equal(originAllowed('GET', '/ws?wsTicket=secret', headers), true);
  for (const origin of ['null', 'https://attacker.invalid', 'http://tunnel.example.test',
    'https://tunnel.example.test:444', 'https://user@tunnel.example.test', 'https://tunnel.example.test/path']) {
    assert.equal(originAllowed('GET', '/ws', { ...headers, origin }), false);
  }
  assert.equal(originAllowed('GET', '/ws', { ...headers, 'x-forwarded-proto': undefined }), false);
  assert.equal(originAllowed('POST', '/api/auth/websocket-ticket', headers), false);
  assert.equal(originAllowed('GET', '/ws', { ...headers, upgrade: undefined }), false);
  assert.equal(originAllowed('GET', '/ws', { host: '192.168.0.110:3773',
    origin: 'http://192.168.0.110:3773', upgrade: 'websocket' }), true);
});

test('removed LAN endpoint cannot be opened by gateway callers', async () => {
  await assert.rejects(createServerGateway({ token: 'ab'.repeat(32), directory: '/unused',
    publicEndpoint: { host: '192.168.1.2', port: 3773 } }), /LAN access has been removed/);
});

test('mobile HTTPS DPoP and WebSocket work with Cloudflare-style TLS termination', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-tunnel-'));
  const previousAgentDirectory = process.env.PI_CODING_AGENT_DIR;
  process.env.PI_CODING_AGENT_DIR = join(directory, 'pi-agent');
  t.after(() => {
    if (previousAgentDirectory === undefined) delete process.env.PI_CODING_AGENT_DIR;
    else process.env.PI_CODING_AGENT_DIR = previousAgentDirectory;
  });
  await mkdir(join(process.env.PI_CODING_AGENT_DIR, 'sessions'), { recursive: true });
  const usageEntry = { type: 'message', id: 'phone-usage', timestamp: '2026-01-01T01:00:00Z',
    message: { role: 'assistant', provider: 'openai-codex', model: 'fixture-model',
      usage: { input: 100, output: 20, cacheRead: 30, cacheWrite: 0, cost: { total: 0.25 } } } };
  await writeFile(join(process.env.PI_CODING_AGENT_DIR, 'sessions', 'fixture.jsonl'),
    JSON.stringify({ type: 'session', id: 'phone-session' }) + '\n' + JSON.stringify(usageEntry));
  await writeFile(join(process.env.PI_CODING_AGENT_DIR, 'sessions', 'fork.jsonl'),
    JSON.stringify({ type: 'session', id: 'fork-session' }) + '\n' + JSON.stringify(usageEntry));
  const gateway = await createServerGateway({ token: 'ab'.repeat(32), directory,
    piConfig: { enabled: false } });
  t.after(async () => { await gateway.close(); await rm(directory, { recursive: true, force: true }); });
  const publicBase = 'https://tunnel.example.test';
  const forwarded = { host: 'tunnel.example.test', 'x-forwarded-proto': 'https' };
  // Node fetch may replace Host; use raw HTTP to emulate cloudflared exactly.
  const request = (path, options = {}) => new Promise((resolve, reject) => {
    const req = http.request(gateway.serverURL + path, {
      method: options.method ?? 'GET', headers: { ...forwarded, ...options.headers },
    }, response => {
      const chunks = []; response.on('data', chunk => chunks.push(chunk));
      response.on('end', () => resolve(new Response(
        [204, 205, 304].includes(response.statusCode) ? null : Buffer.concat(chunks), { status: response.statusCode })));
      response.on('error', reject);
    });
    req.on('error', reject); req.end(Buffer.isBuffer(options.body) ? options.body : options.body?.toString());
  });
  const descriptor = await (await request('/.well-known/t3/environment')).json();
  assert.equal(descriptor.label, 'Pi Mac · Tunnel');
  const { privateKey, publicKey } = await generateKeyPair('ES256', { extractable: true });
  const jwk = await exportJWK(publicKey);
  const proof = (url, accessToken) => new SignJWT({ htu: url, htm: 'POST', jti: randomUUID(),
    ...(accessToken ? { ath: createHash('sha256').update(accessToken).digest('base64url') } : {}) })
    .setProtectedHeader({ alg: 'ES256', typ: 'dpop+jwt', jwk }).setIssuedAt().sign(privateKey);
  // Fixture bootstrap: real relay-issued credentials require account/device acceptance.
  const pairing = await gateway.official.management.pairing({ label: 'Phone fixture' });
  const exchange = await request('/oauth/token', { method: 'POST', headers: {
    'content-type': 'application/x-www-form-urlencoded', dpop: await proof(publicBase + '/oauth/token'),
  }, body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap',
    requested_token_type: 'urn:ietf:params:oauth:token-type:access_token', subject_token: pairing.credential }) });
  const credential = await exchange.json();
  assert.equal(exchange.status, 200, JSON.stringify(credential));
  assert.equal(credential.token_type, 'DPoP');
  assert(credential.scope.split(' ').includes('orchestration:read'));
  assert(credential.scope.split(' ').includes('orchestration:operate'));
  const mintTicket = async (url = publicBase + '/api/auth/websocket-ticket') => request('/api/auth/websocket-ticket', {
    method: 'POST', headers: { authorization: 'DPoP ' + credential.access_token,
      dpop: await proof(url, credential.access_token), 'content-type': 'application/json' }, body: '{}' });
  const wrongProof = await mintTicket('http://tunnel.example.test/api/auth/websocket-ticket');
  assert.equal(wrongProof.status, 401);
  await wrongProof.arrayBuffer();
  const handshake = async (origin, expectedStatus, secret) => {
    if (!secret) {
      const result = await mintTicket(); assert.equal(result.status, 200);
      secret = (await result.json()).ticket;
    }
    const socket = new WebSocket(gateway.serverURL.replace('http:', 'ws:') + '/ws?orchestrationProtocol=2&wsTicket=' + secret,
      { origin, headers: forwarded });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => { socket.terminate(); reject(new Error('Handshake timeout')); }, 5000);
      socket.on('error', () => {});
      socket.once('open', () => {
        clearTimeout(timeout); socket.close();
        try { assert.equal(expectedStatus, 101); resolve(); } catch (error) { reject(error); }
      });
      socket.once('unexpected-response', (_, response) => {
        clearTimeout(timeout); response.resume(); socket.terminate();
        try { assert.equal(response.statusCode, expectedStatus); resolve(); } catch (error) { reject(error); }
      });
    });
  };
  await handshake(publicBase, 101);
  await handshake('https://attacker.invalid', 403);
  await handshake(publicBase, 401, 'invalid-ticket');
  const rpc = async (method, input) => {
    const result = await mintTicket(); assert.equal(result.status, 200);
    const { ticket } = await result.json();
    return call(gateway.serverURL.replace('http:', 'ws:') + '/ws?orchestrationProtocol=2&wsTicket=' + ticket, method, input);
  };
  // The host allowlist must apply in upstream's group middleware to ordinary
  // and streaming RPCs alike, before any handler or subscription is entered.
  await assert.rejects(rpc('server.getProcessDiagnostics', {}),
    error => error._tag === 'EnvironmentAuthorizationError');
  const deniedTicket = await mintTicket();
  const { ticket: deniedSecret } = await deniedTicket.json();
  await assert.rejects(readStream(gateway.serverURL.replace('http:', 'ws:') +
    '/ws?orchestrationProtocol=2&wsTicket=' + deniedSecret, 'subscribeTerminalMetadata',
    {}, { count: 1 }), error => error._tag === 'EnvironmentAuthorizationError');
  // The stock phone's visibility/liveness report must reach background policy,
  // not fail as an unrelated authorization error on every reconnect.
  await rpc('server.reportClientActivity', {
    clientId: 'phone-fixture', clientKind: 'mobile', visible: true, focused: true,
    recentlyInteracted: true, appState: 'active', scopes: [{ type: 'server-config' }],
    observedAt: DateTime.nowUnsafe(),
  });
  // Limits refresh must reach the official provider/source service over the tunnel.
  const refreshed = await rpc('server.refreshProviders', {});
  assert(Array.isArray(refreshed.providers));
  assert(refreshed.providers.every(provider => provider.driver === 'pi'));
  const summary = await rpc('server.getUsageSummary', {
    sinceDay: '2026-01-01', untilDay: '2026-01-01', timeZone: 'UTC',
  });
  assert.equal(summary.buckets.length, 1);
  assert.equal(summary.buckets[0].model, 'fixture-model');
  assert.equal(summary.buckets[0].totals.uncachedInputTokens, 100);
  assert.equal(summary.buckets[0].totals.cachedInputTokens, 30);
  assert.equal(summary.buckets[0].costUsd, 0.25);
  assert.equal(summary.buckets[0].records, 1); // Forked history must not double-count.
  assert(summary.sources.every(source => source.fingerprint.resolvedHomePath ===
    join(process.env.PI_CODING_AGENT_DIR, 'sessions')));
  const configTicket = await mintTicket();
  const { ticket: configSecret } = await configTicket.json();
  const configEvents = await readStream(gateway.serverURL.replace('http:', 'ws:') +
    '/ws?orchestrationProtocol=2&wsTicket=' + configSecret, 'subscribeServerConfig',
    { usageLimitSources: true }, { count: 2 });
  const sourcesEvent = configEvents.find(event => event.type === 'usageLimitSourcesUpdated');
  assert(sourcesEvent);
  assert.match(JSON.stringify(sourcesEvent), /No Pi OAuth accounts/);
  const invalidUsageWindow = { sinceDay: '2026-01-02', untilDay: '2026-01-01', timeZone: 'UTC' };
  // A domain error proves Usage reaches the service rather than the host denylist,
  // without scanning the developer's real transcript directories in this fixture.
  await assert.rejects(rpc('server.getUsageSummary', invalidUsageWindow),
    error => error._tag === 'UsageReadError' && error.reason === 'invalidWindow');
  // Exercise the same DPoP -> ticket -> scheduler path as the unmodified phone.
  assert.deepEqual(await rpc('scheduledTasks.list', {}), { tasks: [] });
  const subscriptionTicket = await mintTicket();
  const { ticket: scheduleTicket } = await subscriptionTicket.json();
  assert.deepEqual(await readStream(gateway.serverURL.replace('http:', 'ws:') +
    '/ws?orchestrationProtocol=2&wsTicket=' + scheduleTicket, 'scheduledTasks.subscribe', {}), [{ tasks: [] }]);
  const projectId = randomUUID();
  await rpc('projects.mutate', { type: 'project.create', commandId: randomUUID(), projectId,
    title: 'Phone schedules', workspaceRoot: directory });
  // New mobile tasks use launchThread, not dispatchCommand. Exercise the real
  // DPoP/ticket route without starting a provider turn.
  const launchInput = { commandId: randomUUID(), projectId, title: 'Phone launch',
    workspaceStrategy: { type: 'root' }, modelSelection: { instanceId: 'pi', model: 'test/model' },
    runtimeMode: 'full-access', interactionMode: 'default' };
  const launched = await rpc('orchestration.launchThread', launchInput);
  assert(launched.threadId);
  assert.equal(launched.projection.thread.title, 'Phone launch');
  const input = { title: 'Phone task', prompt: 'Scheduled phone prompt', enabled: false,
    schedule: { type: 'interval', everyMs: 3600000 }, projectId,
    workspaceStrategy: { type: 'root' }, modelSelection: { instanceId: 'pi', model: 'test/model' },
    runtimeMode: 'full-access', interactionMode: 'default' };
  const { task } = await rpc('scheduledTasks.upsert', input);
  assert.equal(task.enabled, false);
  assert.equal(task.nextRunAt, null);
  const edited = await rpc('scheduledTasks.upsert', { ...input, id: task.id, requireExisting: true,
    schedule: { type: 'fixed_time', timeOfDay: '09:00', weekdays: [1, 2, 3, 4, 5] } });
  assert.equal(edited.task.schedule.type, 'fixed_time');
  const enabled = await rpc('scheduledTasks.setEnabled', { id: task.id, enabled: true });
  assert.equal(enabled.task.enabled, true);
  assert(Number.isFinite(Date.parse(enabled.task.nextRunAt)));
  await rpc('scheduledTasks.setEnabled', { id: task.id, enabled: false });
  assert.equal((await rpc('scheduledTasks.list', {})).tasks[0].id, task.id);
  // Allowlisting must not grant operate access to a read-only phone session.
  const readPairing = await gateway.official.management.pairing({ label: 'Read-only phone' });
  const readExchange = await request('/oauth/token', { method: 'POST', headers: {
    'content-type': 'application/x-www-form-urlencoded', dpop: await proof(publicBase + '/oauth/token'),
  }, body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    subject_token_type: 'urn:t3:params:oauth:token-type:environment-bootstrap',
    requested_token_type: 'urn:ietf:params:oauth:token-type:access_token',
    subject_token: readPairing.credential, scope: 'orchestration:read' }) });
  assert.equal(readExchange.status, 200);
  const readCredential = await readExchange.json();
  const readRpc = async (method, input, stream = false) => {
    const response = await request('/api/auth/websocket-ticket', { method: 'POST', headers: {
      authorization: 'DPoP ' + readCredential.access_token,
      dpop: await proof(publicBase + '/api/auth/websocket-ticket', readCredential.access_token),
      'content-type': 'application/json',
    }, body: '{}' });
    assert.equal(response.status, 200);
    const { ticket } = await response.json();
    const url = gateway.serverURL.replace('http:', 'ws:') + '/ws?orchestrationProtocol=2&wsTicket=' + ticket;
    return stream ? readStream(url, method, input) : call(url, method, input);
  };
  await assert.rejects(readRpc('orchestration.launchThread', { ...launchInput, commandId: randomUUID() }),
    error => error._tag === 'EnvironmentAuthorizationError' && error.requiredScope === 'orchestration:operate');
  await assert.rejects(readRpc('server.refreshProviders', {}),
    error => error._tag === 'EnvironmentAuthorizationError' && error.requiredScope === 'orchestration:operate');
  await assert.rejects(readRpc('server.getUsageSummary', invalidUsageWindow),
    error => error._tag === 'UsageReadError' && error.reason === 'invalidWindow');
  assert.equal((await readRpc('scheduledTasks.list', {})).tasks[0].id, task.id);
  for (const [method, payload] of [
    ['upsert', input], ['setEnabled', { id: task.id, enabled: true }],
    ['delete', { id: task.id }], ['runNow', { id: task.id }],
  ]) {
    await assert.rejects(readRpc('scheduledTasks.' + method, payload),
      error => error._tag === 'EnvironmentAuthorizationError' && error.requiredScope === 'orchestration:operate');
  }
  // Native Git reads cross the same DPoP/ticket transport; writes retain upstream scopes.
  assert.equal((await rpc('vcs.refreshStatus', { cwd: directory })).isRepo, false);
  assert.equal((await readRpc('vcs.listRefs', { cwd: directory })).isRepo, false);
  const vcsEvents = await readRpc('subscribeVcsStatus', { cwd: directory }, true);
  assert.equal(vcsEvents[0]._tag, 'snapshot');
  assert.equal(vcsEvents[0].local.isRepo, false);
  await assert.rejects(readRpc('git.runStackedAction', { cwd: directory, actionId: randomUUID(), action: 'push' }, true),
    error => error._tag === 'EnvironmentAuthorizationError' && error.requiredScope === 'orchestration:operate');
  for (const [method, payload] of [
    ['vcs.init', { cwd: directory }], ['vcs.pull', { cwd: directory }],
    ['vcs.createRef', { cwd: directory, refName: 'denied' }],
    ['vcs.switchRef', { cwd: directory, refName: 'denied' }],
    ['vcs.createWorktree', { cwd: directory, refName: 'main', path: null }],
    ['vcs.removeWorktree', { cwd: directory, path: join(directory, 'denied') }],
    ['git.resolvePullRequest', { cwd: directory, reference: '1' }],
    ['git.preparePullRequestThread', { cwd: directory, reference: '1', mode: 'worktree' }],
  ]) {
    await assert.rejects(readRpc(method, payload),
      error => error._tag === 'EnvironmentAuthorizationError' && error.requiredScope === 'orchestration:operate');
  }
  await assert.rejects(readRpc('review.getDiffPreview', { cwd: directory }),
    error => error._tag === 'EnvironmentAuthorizationError' && error.requiredScope === 'review:write');
  await rpc('scheduledTasks.delete', { id: task.id });
  assert.deepEqual(await rpc('scheduledTasks.list', {}), { tasks: [] });

  // The phone requests a signed URL over its DPoP-authenticated WebSocket,
  // then streams the image through the TLS-terminating tunnel without a Bearer token.
  const bytes = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1cAAAAASUVORK5CYII=', 'base64');
  const signed = await rpc('attachments.createUploadUrl', {
    type: 'image', name: 'phone.png', mimeType: 'image/png', sizeBytes: bytes.length,
  });
  assert.equal((await request(signed.relativeUrl, { method: 'POST', headers: {
    'content-type': 'image/png', 'content-length': String(bytes.length),
  }, body: bytes })).status, 204);
  const asset = await rpc('assets.createUrl', { resource: { _tag: 'attachment', attachmentId: signed.attachmentId } });
  const downloaded = await request(asset.relativeUrl);
  assert.equal(downloaded.status, 200);
  assert.deepEqual(Buffer.from(await downloaded.arrayBuffer()), bytes);
  await rpc('attachments.delete', { attachmentId: signed.attachmentId });
  const logs = await readFile(join(directory, 'server-owned', 'connection-diagnostics.log'), 'utf8');
  assert.match(logs, /https-tunnel/);
  assert.match(logs, /dpop-denied .*"route":"\/api\/auth\/websocket-ticket"/);
  assert.match(logs, /origin-policy/);
  assert.match(logs, /url_mismatch/);
  for (const secret of [pairing.credential, credential.access_token, signed.relativeUrl, 'invalid-ticket', 'wsTicket=']) {
    assert.equal(logs.includes(secret), false);
  }
});
