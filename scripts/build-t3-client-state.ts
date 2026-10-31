import { build, type Plugin } from 'esbuild';
import { readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const upstream = path.join(root, 'third_party/t3code');
const pin = JSON.parse(await readFile(path.join(root, 'sidecars/t3-server/upstream-pin.json'), 'utf8')) as { repository: string; commit: string };
// 上游以普通源码快照保存；版本来自保留的来源记录，不依赖内嵌 Git 仓库。
const source: unknown = JSON.parse(await readFile(path.join(root, 'third_party/t3code-source.json'), 'utf8'));
if (typeof source !== 'object' || source === null
  || !('repository' in source) || source.repository !== pin.repository
  || !('commit' in source) || typeof source.commit !== 'string' || !/^[a-f0-9]{40}$/.test(source.commit)) {
  throw new Error('Invalid official client source provenance');
}
const commit = source.commit;
if (commit !== pin.commit) throw new Error('Client reducers and Server must use the same pinned commit');
const workspace: Plugin = {
  name: 'official-client-workspace',
  setup(builder) {
    builder.onResolve({ filter: /^@t3tools\// }, async args => {
      const [name, ...rest] = args.path.slice('@t3tools/'.length).split('/');
      const directory = path.join(upstream, 'packages', name!);
      const manifest = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8')) as {
        exports: Record<string, string | { import: string }>;
      };
      const spec = manifest.exports[rest.length ? './' + rest.join('/') : '.'];
      if (!spec) throw new Error('Missing official export: ' + args.path);
      return { path: path.resolve(directory, typeof spec === 'string' ? spec : spec.import) };
    });
  },
};
const result = await build({
  entryPoints: [path.join(root, 'sidecars/t3-client-state/index.ts')],
  bundle: true, write: false, metafile: true, platform: 'browser', format: 'iife', globalName: 'T3NativeState',
  target: 'safari17', minify: true, plugins: [workspace],
  nodePaths: [path.join(root, 'sidecars/t3-server/node_modules')],
  banner: { js: `// Official T3 Code client reducers, pinned ${commit}. See T3-CLIENT-LICENSE.txt. Generated; do not edit.` },
});
// 浏览器 bundle 还包含 Effect 等依赖，不能只携带 T3 仓库本身的许可证。
const dependencyDirectories = new Set<string>();
for (const output of Object.values(result.metafile.outputs)) {
  for (const [input, contribution] of Object.entries(output.inputs)) {
    if (contribution.bytesInOutput === 0) continue;
    const absolute = path.resolve(root, input);
    const marker = '/node_modules/';
    const index = absolute.lastIndexOf(marker);
    if (index < 0) continue;
    const parts = absolute.slice(index + marker.length).split('/');
    const name = parts.slice(0, parts[0]!.startsWith('@') ? 2 : 1).join('/');
    dependencyDirectories.add(absolute.slice(0, index + marker.length) + name);
  }
}
const licenses = [`T3 Code ${commit}\n\n${await readFile(path.join(upstream, 'LICENSE'), 'utf8')}`];
for (const directory of [...dependencyDirectories].sort()) {
  const manifest = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8')) as {name: string; version: string};
  let license: string | undefined;
  for (const name of ['LICENSE', 'LICENSE.md', 'LICENSE.txt', 'license', 'license.md']) {
    try { license = await readFile(path.join(directory, name), 'utf8'); break; }
    catch (error) { if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error; }
  }
  if (!license) throw new Error('Missing bundled dependency license: ' + manifest.name);
  licenses.push(`${manifest.name}@${manifest.version}\n\n${license}`);
}
const directory = path.join(root, 'Sources/PiMacApp/Resources');
const files = new Map([
  ['t3-client-state.js', result.outputFiles[0]!.contents],
  ['T3-CLIENT-LICENSE.txt', Buffer.from(licenses.join('\n\n----------------------------------------\n\n'))],
]);
for (const [name, contents] of files) {
  const destination = path.join(directory, name);
  if (process.argv.includes('--check')) {
    if (!Buffer.from(await readFile(destination)).equals(contents)) throw new Error('Stale client state resource: ' + name);
  } else {
    await writeFile(destination, contents);
  }
}
if (process.argv.includes('--check')) {
  // 从官方 exports 生成类型解析映射，不在宿主维护第二份工作区包列表。
  const ts = await import('typescript');
  const paths: Record<string, string[]> = {
    effect: ['sidecars/t3-server/node_modules/effect/dist/index.d.ts'],
    'effect/*': ['sidecars/t3-server/node_modules/effect/dist/*.d.ts'],
    '*': ['sidecars/t3-server/node_modules/*', 'node_modules/*'],
  };
  for (const directory of await readdir(path.join(upstream, 'packages'), { withFileTypes: true })) {
    if (!directory.isDirectory()) continue;
    const location = path.join(upstream, 'packages', directory.name);
    const manifest = JSON.parse(await readFile(path.join(location, 'package.json'), 'utf8')) as {
      name: string; exports?: Record<string, string | { types?: string; import?: string }>;
    };
    for (const [name, spec] of Object.entries(manifest.exports ?? {})) {
      const file = typeof spec === 'string' ? spec : spec.types ?? spec.import;
      if (file) paths[manifest.name + (name === '.' ? '' : name.slice(1))] = [path.resolve(location, file)];
    }
  }
  const program = ts.createProgram([
    path.join(root, 'sidecars/t3-client-state/index.ts'), fileURLToPath(import.meta.url),
  ], {
    noEmit: true, strict: true, skipLibCheck: true, allowImportingTsExtensions: true,
    target: ts.ScriptTarget.ES2023, module: ts.ModuleKind.ESNext,
    moduleResolution: ts.ModuleResolutionKind.Bundler, types: ['node'], baseUrl: root, paths,
  });
  const diagnostics = ts.getPreEmitDiagnostics(program);
  if (diagnostics.length) {
    throw new Error(ts.formatDiagnosticsWithColorAndContext(diagnostics, {
      getCurrentDirectory: () => root, getCanonicalFileName: file => file, getNewLine: () => '\n',
    }));
  }
}
console.log(`Official client reducers ${process.argv.includes('--check') ? 'verified and typechecked' : 'bundled'} (${commit})`);
