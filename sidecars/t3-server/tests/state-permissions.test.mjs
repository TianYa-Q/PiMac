import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, chmod, symlink, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';

const token = 'ab'.repeat(32);
test('downloaded executable tools do not prevent subsequent server startup', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-tools-'));
  let gateway;
  t.after(async () => { await gateway?.close(); await rm(directory, { recursive: true, force: true }); });
  const tools = join(directory, 'server-owned/tools/cloudflared/version/platform');
  await mkdir(tools, { recursive: true, mode: 0o700 });
  const binary = join(tools, 'cloudflared');
  await writeFile(binary, 'fixture'); await chmod(binary, 0o755);
  gateway = await createServerGateway({ token, directory });
  assert(gateway.serverURL);
  await gateway.close(); gateway = undefined;
  // The exception is only for tools, not secrets or any other persisted state.
  const secret = join(directory, 'server-owned/userdata/secrets/fixture.bin');
  await writeFile(secret, 'fixture'); await chmod(secret, 0o644);
  await assert.rejects(createServerGateway({ token, directory }), /Unsafe T3 Server state/);
  await rm(secret);
  await chmod(binary, 0o775);
  await assert.rejects(createServerGateway({ token, directory }), /Unsafe T3 Server state/);
  await rm(binary);
  await symlink('/bin/sh', binary);
  await assert.rejects(createServerGateway({ token, directory }), /Unsafe T3 Server state/);
});
