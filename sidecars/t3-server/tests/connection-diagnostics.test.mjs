import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, stat, rm, writeFile } from 'node:fs/promises';
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

test('logging failures do not interrupt authentication', () => {
  const diagnostics = createConnectionDiagnostics('/nonexistent/pimac/log-directory');
  assert.doesNotThrow(() => diagnostics.record('response', { status: 200 }));
  assert.match(diagnostics.summary, /200/);
});
