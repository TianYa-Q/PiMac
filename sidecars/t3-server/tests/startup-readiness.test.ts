import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, stat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import * as Effect from 'effect/Effect';
import { setImmediate } from 'node:timers/promises';
import { createStartupDiagnostics, traceStartupPhase } from '../startup-diagnostics.ts';
import { createServerGateway } from './fixtures/protocol-server.mjs';

async function directory() {
  const root = new URL('../../../tmp/t3-startup/', import.meta.url);
  await mkdir(root, { recursive: true });
  const result = await mkdtemp(new URL('fixture-', root).pathname);
  return result;
}

async function records(root: string) {
  return (await readFile(path.join(root, 'startup-diagnostics.log'), 'utf8')).trim().split('\n')
    .map(line => JSON.parse(line.slice(line.indexOf(' ') + 1)));
}

test('phase timing preserves success, failure and interruption without logging payloads', async t => {
  const root = await directory();
  t.after(() => execFileSync('trash', [root]));
  const diagnostics = createStartupDiagnostics(root);
  assert.equal(await Effect.runPromise(traceStartupPhase('test.success', Effect.succeed('private payload'), diagnostics)), 'private payload');
  await assert.rejects(Effect.runPromise(traceStartupPhase('test.failure', Effect.fail(new Error('private failure')), diagnostics)));
  const controller = new AbortController();
  const pending = Effect.runPromise(traceStartupPhase('test.interrupt', Effect.never, diagnostics), { signal: controller.signal });
  const rejected = assert.rejects(pending);
  await setImmediate();
  controller.abort();
  await rejected;
  const rows = await records(root);
  assert.deepEqual(rows.map(row => [row.phase, row.state]), [
    ['test.success', 'start'], ['test.success', 'success'],
    ['test.failure', 'start'], ['test.failure', 'failure'],
    ['test.interrupt', 'start'], ['test.interrupt', 'failure'],
  ]);
  assert(rows.every(row => row.elapsedMs >= 0 && row.processMs >= 0));
  assert(!JSON.stringify(rows).includes('private'));
  assert.equal((await stat(path.join(root, 'startup-diagnostics.log'))).mode & 0o077, 0);
});

test('real gateway readiness waits for the official command gate and auth works immediately', async t => {
  const root = await directory();
  const gateway = await createServerGateway({ token: 'ab'.repeat(32), directory: root, piConfig: { enabled: false } });
  t.after(async () => { await gateway.close(); execFileSync('trash', [root]); });
  const rows = await records(path.join(root, 'server-owned'));
  const command = rows.findIndex(row => row.phase === 'commands.ready');
  const ready = rows.findIndex(row => row.phase === 'server.ready');
  assert(command >= 0 && ready > command, JSON.stringify(rows));
  for (const phase of ['path.hydration', 'settings.start', 'orchestration-v2.recovery', 'orchestration-v2.delegated-tasks.recover']) {
    assert(rows.some(row => row.phase === phase && row.state === 'start'), phase);
    assert(rows.some(row => row.phase === phase && row.state === 'success' && row.durationMs >= 0), phase);
  }
  await new Promise<void>((resolve, reject) => {
    gateway.server.once('error', reject);
    gateway.server.listen(0, '127.0.0.1', resolve);
  });
  const address = gateway.server.address();
  assert(address !== null && typeof address !== 'string');
  const credential = await fetch(`http://127.0.0.1:${address.port}/internal/auth/desktop-session`, {
    method: 'POST', headers: { authorization: 'Bearer ' + 'ab'.repeat(32) },
    signal: AbortSignal.timeout(2000),
  });
  assert.equal(credential.status, 200);
  const { token } = await credential.json();
  const response = await fetch(gateway.serverURL + '/api/auth/session', {
    headers: { authorization: 'Bearer ' + token }, signal: AbortSignal.timeout(2000),
  });
  assert.equal(response.status, 200);
  assert.equal((await response.json()).authenticated, true);
  const authRows = (await records(path.join(root, 'server-owned'))).filter(row => row.phase === 'auth.session.verify');
  assert.deepEqual(authRows.map(row => row.state), ['start', 'success']);
  assert(authRows[1].durationMs < 2000);
  assert(!(await readFile(path.join(root, 'server-owned', 'startup-diagnostics.log'), 'utf8')).includes(token));
});
