import test from 'node:test';
import { mkdtemp, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { build } from 'esbuild';
import { plugin } from '../build.mjs';

// 通过正式 plugin 应用宿主补丁，不能仅测试未打包的上游源码或 SQL mock。
test('official authentication stays usable during background SQLite transactions', { timeout: 30000 }, async t => {
  const base = new URL('../../../tmp/t3-auth-block/', import.meta.url);
  await mkdir(base, { recursive: true });
  const directory = await mkdtemp(new URL('fixture-', base).pathname);
  t.after(() => execFileSync('trash', [directory]));
  const output = directory + '/auth.mjs';
  await build({
    entryPoints: [new URL('./fixtures/auth-contention.ts', import.meta.url).pathname],
    outfile: output, bundle: true, platform: 'node', target: 'node24', format: 'esm', plugins: [plugin],
    banner: { js: 'import { createRequire } from "node:module"; const require = createRequire(import.meta.url);' },
  });
  const { verifyUnderContention } = await import(output);
  for (const lane of ['reader', 'writer', 'both']) {
    await t.test(lane + ' contention preserves authentication, revocation and transaction visibility', async child => {
      await verifyUnderContention(directory + '/' + lane, lane, child.signal);
    });
  }
});
