import test from 'node:test';
import assert from 'node:assert/strict';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { chmod, mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { build } from 'esbuild';
import { loadPiThinkingDefaults } from '../pi-thinking-defaults.ts';

const exec = promisify(execFile);
const root = fileURLToPath(new URL('../', import.meta.url));
const upstream = join(root, 'upstream');
const require = createRequire(import.meta.url);

test('Pi discovery publishes effective thinking defaults for inactive models', async t => {
  const temporaryRoot = resolve(root, '../../tmp');
  await mkdir(temporaryRoot, { recursive: true });
  const directory = await mkdtemp(join(temporaryRoot, 'thinking-defaults-'));
  t.after(async () => { await exec('trash', [directory]); });
  const patches: Record<string, Array<{ oldText: string; newText: string; count?: number }>> =
    JSON.parse(await readFile(join(root, 'patches.json'), 'utf8'));
  const bundle = join(directory, 'status.js');
  await build({
    stdin: {
      contents: `
        import * as Effect from 'effect/Effect';
        import * as NodeServices from '@effect/platform-node/NodeServices';
        import { checkPiProviderStatus } from './upstream/packages/provider-pi/src/server/status.ts';
        export const probe = (binaryPath, environment, cwd) => Effect.runPromise(
          checkPiProviderStatus({ enabled: true, binaryPath, launchArgs: '', customModels: [] }, environment, cwd)
            .pipe(Effect.provide(NodeServices.layer)));
      `,
      resolveDir: root, loader: 'ts',
    },
    outfile: bundle, bundle: true, platform: 'node', format: 'esm', target: 'node24',
    treeShaking: false,
    banner: { js: 'import {createRequire} from "node:module"; const require = createRequire(import.meta.url);' },
    plugins: [{ name: 'patched-thinking-discovery', setup(builder) {
      builder.onResolve({ filter: /^pimac:/ }, args => ({ path: join(root, args.path.slice(6)) }));
      builder.onResolve({ filter: /^@t3tools\// }, async args => {
        const [name, ...rest] = args.path.slice('@t3tools/'.length).split('/');
        const pkg = join(upstream, 'packages', name);
        const manifest = JSON.parse(await readFile(join(pkg, 'package.json'), 'utf8'));
        const entry = manifest.exports[rest.length ? './' + rest.join('/') : '.'];
        return { path: resolve(pkg, typeof entry === 'string' ? entry : entry.import) };
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
    } }],
  });
  await writeFile(join(directory, 'package.json'), JSON.stringify({ type: 'module' }));
  const binary = join(directory, 'fixture-pi.ts');
  await writeFile(binary, `#!/usr/bin/env -S node --import ${require.resolve('tsx/esm')}
import { createInterface } from 'node:readline';
const models = [
  { provider: 'fixture', id: 'active', reasoning: true },
  { provider: 'fixture', id: 'global', reasoning: true },
  { provider: 'fixture', id: 'override', reasoning: true },
  { provider: 'fixture', id: 'clamped', reasoning: true, thinkingLevelMap: { off: null, minimal: null, low: null, medium: null } },
  { provider: 'fixture', id: 'plain', reasoning: false },
];
if (process.argv.includes('--version')) { console.log('pi 1.3.0'); process.exit(0); }
for await (const line of createInterface({ input: process.stdin })) {
  const command = JSON.parse(line);
  const data = command.type === 'get_state'
    ? { model: models[0], thinkingLevel: 'low' }
    : command.type === 'get_available_models' ? { models } : { commands: [] };
  console.log(JSON.stringify({ type: 'response', command: command.type, id: command.id, success: true, data }));
}
`);
  await chmod(binary, 0o700);
  const agent = join(directory, 'agent');
  const project = join(directory, 'project');
  await mkdir(agent);
  await mkdir(join(project, '.pi'), { recursive: true });
  await writeFile(join(agent, 'settings.json'), JSON.stringify({ defaultThinkingLevel: 'medium',
    modelThinkingLevels: { 'fixture/override': 'high' } }));
  const { probe } = await import(pathToFileURL(bundle).href);
  const environment = { ...process.env, PI_CODING_AGENT_DIR: agent };
  const defaults = async () => {
    const snapshot = await probe(binary, environment, project);
    assert.equal(snapshot.auth.status, 'authenticated', snapshot.message);
    return Object.fromEntries(snapshot.models.map((model: {
      slug: string;
      capabilities: { optionDescriptors: Array<{ id: string; options?: Array<{ id: string; isDefault?: boolean }> }> };
    }) => [model.slug, model.capabilities.optionDescriptors.find(option => option.id === 'thinking')
      ?.options?.find(option => option.isDefault)?.id]));
  };
  assert.deepEqual(await defaults(), { default: undefined, 'fixture/active': 'low',
    'fixture/global': 'medium', 'fixture/override': 'high', 'fixture/clamped': 'high', 'fixture/plain': undefined });
  await writeFile(join(project, '.pi/settings.json'), JSON.stringify({ defaultThinkingLevel: 'high',
    modelThinkingLevels: { 'fixture/override': 'minimal' } }));
  assert.deepEqual(await defaults(), { default: undefined, 'fixture/active': 'low',
    'fixture/global': 'high', 'fixture/override': 'minimal', 'fixture/clamped': 'high', 'fixture/plain': undefined });
  await exec('trash', [join(agent, 'settings.json'), join(project, '.pi/settings.json')]);
  assert.deepEqual(await defaults(), { default: undefined, 'fixture/active': 'low',
    'fixture/global': 'low', 'fixture/override': 'low', 'fixture/clamped': 'high', 'fixture/plain': undefined });
  await writeFile(join(agent, 'settings.json'), '{broken');
  const failed = await probe(binary, environment, project);
  assert.equal(failed.auth.status, 'unknown');
  assert.match(failed.message, /could not refresh/);
});

test('Pi thinking settings merge model overrides and reject corrupt configuration', async t => {
  const temporaryRoot = resolve(root, '../../tmp');
  await mkdir(temporaryRoot, { recursive: true });
  const directory = await mkdtemp(join(temporaryRoot, 'thinking-settings-'));
  t.after(async () => { await exec('trash', [directory]); });
  const agent = join(directory, 'agent');
  const project = join(directory, 'project');
  await mkdir(agent);
  await mkdir(join(project, '.pi'), { recursive: true });
  const environment = { HOME: directory, PI_CODING_AGENT_DIR: '~/agent' };
  const globalFile = join(agent, 'settings.json');
  const projectFile = join(project, '.pi/settings.json');
  await writeFile(globalFile, JSON.stringify({ defaultThinkingLevel: 'medium',
    modelThinkingLevels: { 'fixture/a': 'high', 'fixture/b': 'max' } }));
  await writeFile(projectFile, JSON.stringify({ modelThinkingLevels: { 'fixture/a': 'low' } }));
  const settings = await loadPiThinkingDefaults(environment, project);
  assert.equal(settings.defaultLevel, 'medium');
  assert.deepEqual([...settings.modelLevels], [['fixture/a', 'low'], ['fixture/b', 'max']]);
  for (const invalid of ['{broken', 'null', '[]', '{"defaultThinkingLevel":"invalid"}',
    '{"modelThinkingLevels":[]}', '{"modelThinkingLevels":{"fixture/a":null}}']) {
    await writeFile(projectFile, invalid);
    await assert.rejects(loadPiThinkingDefaults(environment, project));
  }
  await exec('trash', [projectFile, globalFile]);
  const empty = await loadPiThinkingDefaults(environment, project);
  assert.equal(empty.defaultLevel, undefined);
  assert.equal(empty.modelLevels.size, 0);
});
