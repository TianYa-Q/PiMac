import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, stat, rm, writeFile, symlink } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { connectionRoute, createConnectionDiagnostics } from '../connection-diagnostics.mjs';

test('diagnostics retain only bounded summaries and one private rotated log', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-connection-log-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const diagnostics = createConnectionDiagnostics(directory);
  for (let i = 0; i < 25; i++) diagnostics.record('response', { route: '/oauth/token', status: 401,
    authorization: 'secret-token', dpop: 'secret-proof', body: 'secret-transcript' });
  assert.equal(diagnostics.summary.split('\n').length, 20);
  const file = join(directory, 'connection-diagnostics.log');
  const contents = await readFile(file, 'utf8');
  assert.equal(contents.includes('secret-'), false);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  await writeFile(file, 'x'.repeat(256 * 1024 + 1));
  diagnostics.record('response', { status: 200 });
  assert.equal((await readFile(file + '.1', 'utf8')).length, 256 * 1024 + 1);
  assert.ok((await stat(file)).size < 1024);
  assert.equal(connectionRoute('/ws?wsTicket=secret'), '/ws');
  assert.equal(connectionRoute('/api/orchestration/threads/private-id'), null);
});

test('detailed connector logs retain exact network errors, separate from UI, with bounded rotation', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-connector-log-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const diagnostics = createConnectionDiagnostics(directory);
  const output = 'ERR Failed to dial a http2 connection to edge error="dial tcp 198.41.192.7:7844: i/o timeout" connIndex=0';
  diagnostics.record('tunnel-health', { reason: 'connecting' });
  diagnostics.recordConnectorOutput(123, output);
  const file = join(directory, 'tunnel-connector.log');
  const contents = await readFile(file, 'utf8');
  assert.equal(JSON.parse(contents.trim().split('\n')[1].split(' cloudflared ')[1]).output, output);
  assert(!diagnostics.summary.includes('198.41.192.7'));
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  await writeFile(file, 'x'.repeat(2 * 1024 * 1024));
  diagnostics.recordConnectorOutput(123, output);
  assert.equal((await stat(file + '.1')).size, 2 * 1024 * 1024);
  assert.equal((await stat(file)).mode & 0o777, 0o600);
  assert((await stat(file)).size < 1024);
});

test('logs do not follow symlinks', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-log-symlink-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const target = join(directory, 'target'); await writeFile(target, 'untouched', { mode: 0o600 });
  for (const file of ['tunnel-connector.log', 'connection-diagnostics.log']) await symlink(target, join(directory, file));
  const diagnostics = createConnectionDiagnostics(directory);
  diagnostics.record('tunnel-health', { reason: 'connecting' });
  diagnostics.recordConnectorOutput(123, 'error');
  assert.equal(await readFile(target, 'utf8'), 'untouched');
});

test('logging failures do not interrupt authentication', () => {
  const diagnostics = createConnectionDiagnostics('/nonexistent/pimac/log-directory');
  assert.doesNotThrow(() => diagnostics.record('response', { status: 200 }));
  assert.match(diagnostics.summary, /200/);
});
