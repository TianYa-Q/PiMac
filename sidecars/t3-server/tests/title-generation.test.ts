import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { chmod, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'esbuild';

const exec = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
const upstream = join(root, 'upstream');
const patches: Record<string, Array<{ oldText: string; newText: string; count?: number }>> =
  JSON.parse(await readFile(join(root, 'patches.json'), 'utf8'));

// 只打包受影响的真实上游代码，不构建应用、不访问正在运行的 Server 或用户账号。
test('background titles keep extension providers, model selection and credential isolation', async t => {
  const temporaryRoot = resolve(root, '../../tmp');
  await mkdir(temporaryRoot, { recursive: true });
  const directory = await mkdtemp(join(temporaryRoot, 'title-generation-'));
  t.after(async () => { await exec('trash', [directory]); });
  const bundle = join(directory, 'runner.mjs');
  await build({
    stdin: {
      contents: `
        import * as Effect from 'effect/Effect';
        import * as NodeServices from '@effect/platform-node/NodeServices';
        import { makePiTextGeneration } from './upstream/packages/provider-pi/src/server/textGeneration.ts';
        const generation = Effect.gen(function* () {
          const service = yield* makePiTextGeneration({ enabled: true,
            binaryPath: process.argv[2], launchArgs: '--extension fixture-provider.ts --tools read', customModels: [] }, process.env);
          return yield* service.generateThreadTitle({ cwd: process.cwd(), message: 'Fix title generation',
            modelSelection: { instanceId: 'pi', model: process.argv[3] } });
        }).pipe(Effect.provide(NodeServices.layer));
        try { console.log(JSON.stringify(await Effect.runPromise(generation))); }
        catch (error) { console.error(String(error)); process.exitCode = 1; }
      `,
      resolveDir: root,
      loader: 'ts',
    },
    outfile: bundle, bundle: true, platform: 'node', format: 'esm', target: 'node24',
    // 与正式 Server 一样保留 Effect 循环模块初始化顺序。
    treeShaking: false,
    banner: { js: 'import {createRequire} from "node:module"; const require = createRequire(import.meta.url);' },
    plugins: [{
      name: 'patched-title-generation',
      setup(builder) {
        builder.onResolve({ filter: /^@t3tools\// }, async args => {
          const [name, ...rest] = args.path.slice('@t3tools/'.length).split('/');
          const directory = join(upstream, 'packages', name);
          const manifest = JSON.parse(await readFile(join(directory, 'package.json'), 'utf8'));
          const entry = manifest.exports[rest.length ? './' + rest.join('/') : '.'];
          return { path: resolve(directory, typeof entry === 'string' ? entry : entry.import) };
        });
        builder.onLoad({ filter: /\.ts$/ }, async args => {
          if (!args.path.startsWith(upstream + '/')) return;
          let contents = await readFile(args.path, 'utf8');
          for (const patch of patches[args.path.slice(upstream.length + 1)] ?? []) {
            assert.equal(contents.split(patch.oldText).length - 1, patch.count ?? 1);
            contents = contents.replaceAll(patch.oldText, patch.newText);
          }
          return { contents, loader: 'ts', resolveDir: dirname(args.path) };
        });
      },
    }],
  });

  const binary = join(directory, 'fixture-pi');
  const records = join(directory, 'requests.jsonl');
  // 协议替身模拟扩展 Provider：禁用扩展或移除显式扩展都会导致 set_model 失败。
  // 不调用外部模型；断言的是完整标题生成 RPC 路径，而非 SQL 或源码字符串。
  const fixture = `
    const fs = require('node:fs');
    const args = process.argv.slice(1);
    fs.appendFileSync(process.env.FIXTURE_RECORDS, JSON.stringify({ args,
      leaked: Object.keys(process.env).filter(key =>
        ['T3_MCP_URL', 'T3_MCP_BEARER_TOKEN', 'T3_PI_MCP_EXTENSION_PATH'].includes(key)) }) + '\\n');
    let selected;
    require('node:readline').createInterface({ input: process.stdin }).on('line', line => {
      const command = JSON.parse(line);
      fs.appendFileSync(process.env.FIXTURE_RECORDS, JSON.stringify(command) + '\\n');
      const reply = { type: 'response', id: command.id, command: command.type, success: true };
      if (command.type === 'set_model') {
        selected = command.provider;
        if (selected === 'antigravity' && (args.includes('--no-extensions') || !args.includes('fixture-provider.ts'))) {
          reply.success = false; reply.error = 'Extension provider unavailable';
        }
      }
      if (command.type === 'get_last_assistant_text') reply.data = { text:
        process.env.FIXTURE_EMPTY === '1' ? '' : JSON.stringify({ title: selected + ' generated title' }) };
      console.log(JSON.stringify(reply));
      if (command.type === 'prompt') console.log(JSON.stringify({ type: 'agent_settled' }));
    });
  `;
  const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
  await writeFile(binary, `#!/bin/sh\nexec ${quote(process.execPath)} -e ${quote(fixture)} -- "$@"\n`);
  await chmod(binary, 0o700);
  const environment = { ...process.env, FIXTURE_RECORDS: records,
    T3_MCP_URL: 'http://fixture.invalid', T3_MCP_BEARER_TOKEN: 'fixture-secret',
    T3_PI_MCP_EXTENSION_PATH: '/fixture/inherited-extension.ts' };
  for (const model of ['antigravity/gemini-3.8-flash', 'openai-codex/gpt-6.1-sol']) {
    const { stdout } = await exec(process.execPath, [bundle, binary, model], { env: environment });
    assert.equal(JSON.parse(stdout).title, model.split('/')[0] + ' generated title');
  }
  const log: Array<Record<string, unknown>> = (await readFile(records, 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  for (const launch of log.filter(row => Array.isArray(row.args))) {
    const args = launch.args as string[];
    assert(args.includes('--no-session'));
    assert(args.includes('--no-tools'));
    assert(!args.includes('--tools'));
    assert(!args.includes('--no-extensions'));
    assert(args.includes('fixture-provider.ts'));
    assert.deepEqual(launch.leaked, []);
  }
  assert.deepEqual(log.filter(row => row.type === 'set_model').map(row => [row.provider, row.modelId]), [
    ['antigravity', 'gemini-3.8-flash'], ['openai-codex', 'gpt-6.1-sol'],
  ]);
  await assert.rejects(exec(process.execPath, [bundle, binary, 'antigravity/gemini-3.8-flash'], {
    env: { ...environment, FIXTURE_EMPTY: '1' },
  }), /Pi returned empty output/);
});
