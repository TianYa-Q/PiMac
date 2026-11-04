import test from 'node:test';
import { mkdtemp, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { build } from 'esbuild';
import { plugin } from '../build.mjs';

// 正式补丁与打包链路，隔离数据库；不接触真实会话、凭据或运行中的 Server。
test('lifecycle confirmation responses bypass waiting work without losing FIFO or retry ordering', { timeout: 30000 }, async () => {
  const base = new URL('../../../tmp/goal-response/', import.meta.url);
  await mkdir(base, { recursive: true });
  const directory = await mkdtemp(new URL('fixture-', base).pathname);
  try {
    const output = directory + '/outbox.mjs';
    await build({
      entryPoints: [new URL('./fixtures/runtime-response-outbox.ts', import.meta.url).pathname],
      outfile: output, bundle: true, platform: 'node', target: 'node24', format: 'esm',
      treeShaking: false, plugins: [plugin],
      banner: { js: 'import { createRequire } from "node:module"; const require = createRequire(import.meta.url);' },
    });
    const { verifyResponseLane } = await import(output);
    await verifyResponseLane();
  } finally {
    execFileSync('trash', [directory]);
  }
});
