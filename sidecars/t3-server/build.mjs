import { build } from 'esbuild';
import { readFile, writeFile, mkdir, cp, access, readdir, stat, mkdtemp, rename } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { dirname, resolve, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const root = dirname(fileURLToPath(import.meta.url));
const upstream = join(root, 'upstream');
const require = createRequire(import.meta.url);
const pin = JSON.parse(await readFile(join(root, 'upstream-pin.json'), 'utf8'));
for (const [file, expected] of Object.entries(pin.files)) {
  if (createHash('sha256').update(await readFile(join(upstream, file))).digest('hex') !== expected) throw new Error(`Changed upstream file: ${file}`);
}
const patches = JSON.parse(await readFile(join(root, 'patches.json'), 'utf8'));
// SDK 的动态 chunk、CLI 资源及原生库必须保留在磁盘上，不能只解除 stub 后交给 esbuild 内联。
// 同一组根依赖同时控制 bundle 边界和随应用复制的传递依赖闭包。
const runtimePackages = [
  '@anthropic-ai/claude-agent-sdk', '@cursor/sdk', '@ff-labs/fff-node',
  '@muse-code/sdk', '@napi-rs/keyring', '@opencode-ai/sdk', 'node-pty', 'playwright-core',
];
const nativePatches = {
  '@ff-labs/fff-node': 'patches/@ff-labs__fff-node@0.11.0.patch',
  'node-pty': 'patches/node-pty@1.2.0-beta.15.patch',
};

async function stageRuntime(vendor, check) {
  const lockText = await readFile(join(root, 'package-lock.json'), 'utf8');
  const lock = JSON.parse(lockText);
  const packages = new Map();
  const exists = async path => access(path).then(() => true, error => {
    if (error.code === 'ENOENT') return false;
    throw error;
  });
  // 从每个真实 package 目录按 Node 查找规则解析，保留 npm 的嵌套布局及同名多版本。
  // optional 的平台包可合法缺席；必需依赖缺失或 lock 不匹配必须明确失败。
  async function visit(name, from, optional = false) {
    let directory = from;
    let source;
    while (directory.startsWith(root)) {
      const candidate = join(directory, 'node_modules', name);
      if (await exists(join(candidate, 'package.json'))) { source = candidate; break; }
      directory = dirname(directory);
    }
    if (!source) {
      if (optional) return;
      throw new Error(`Missing runtime dependency ${name} from ${from}; run npm ci --ignore-scripts`);
    }
    const path = relative(root, source).split(sep).join('/');
    if (packages.has(path)) return;
    const manifest = JSON.parse(await readFile(join(source, 'package.json'), 'utf8'));
    if (lock.packages[path]?.version !== manifest.version) throw new Error(`Runtime dependency differs from lock: ${path}`);
    packages.set(path, source);
    const dependencies = { ...manifest.peerDependencies, ...manifest.dependencies, ...manifest.optionalDependencies };
    for (const dependency of Object.keys(dependencies)) {
      await visit(dependency, source, Object.hasOwn(manifest.optionalDependencies ?? {}, dependency) ||
        manifest.peerDependenciesMeta?.[dependency]?.optional === true);
    }
  }
  for (const name of runtimePackages) await visit(name, root);
  const temporaryRoot = resolve(root, '../../tmp');
  await mkdir(temporaryRoot, { recursive: true });
  // 所有临时内容放在项目 tmp；替换/清理只用 trash，不触碰正在运行的 .app。
  execFileSync('which', ['trash'], { stdio: 'ignore' });
  const stage = await mkdtemp(join(temporaryRoot, 't3-runtime-'));
  try {
    for (const [path, source] of packages) {
      await cp(source, join(stage, path), { recursive: true,
        filter: path => path === source || !relative(source, path).split(sep).includes('node_modules') });
    }
    for (const [name, patch] of Object.entries(nativePatches)) {
      // 从文件系统根应用绝对目标路径，避免 Git 在仓库内 tmp 子目录中静默跳过补丁。
      execFileSync('git', ['apply', '--no-index', '--unsafe-paths', '--directory=' + join(stage, 'node_modules', name), join(upstream, patch)], { cwd: '/' });
    }
    // 安装脚本被禁用：只接受 npm 锁定的平台预编译件，不在打包时下载或本地编译原生代码。
    const nativeRequire = createRequire(join(stage, 'runtime.cjs'));
    for (const name of ['node-pty', '@ff-labs/fff-node', '@napi-rs/keyring', '@cursor/sdk', '@cursor/sdk/sqlite']) {
      nativeRequire(name);
    }
    if (!nativeRequire('@ff-labs/fff-node').binaryExists()) throw new Error('fff-node platform library is missing');
    const helper = join(stage, 'node_modules/node-pty/prebuilds', `${process.platform}-${process.arch}`, 'spawn-helper');
    if (process.platform === 'darwin' && !await exists(helper)) throw new Error(`Missing node-pty spawn helper: ${helper}`);
    async function fingerprint(directory, prefix = '') {
      const entries = [];
      for (const entry of (await readdir(directory, { withFileTypes: true })).sort((a, b) => a.name.localeCompare(b.name, 'en'))) {
        const path = join(directory, entry.name);
        const name = prefix + entry.name;
        if (entry.isDirectory()) entries.push(...await fingerprint(path, name + '/'));
        else if (entry.isFile()) entries.push([name, {
          sha256: createHash('sha256').update(await readFile(path)).digest('hex'),
          mode: (await stat(path)).mode & 0o777,
        }]);
        else throw new Error(`Unexpected runtime file type: ${path}`);
      }
      return entries;
    }
    const manifest = {
      platform: process.platform, arch: process.arch,
      lock: createHash('sha256').update(lockText).digest('hex'),
      patches: Object.fromEntries(Object.values(nativePatches).map(path => [path, pin.files[path]])),
      packages: [...packages.keys()].sort(),
      files: Object.fromEntries(await fingerprint(join(stage, 'node_modules'))),
    };
    const manifestText = JSON.stringify(manifest, null, 2) + '\n';
    const manifestPath = join(vendor, 'native-runtime.json');
    const destination = join(vendor, 'node_modules');
    if (check) {
      if (await readFile(manifestPath, 'utf8') !== manifestText ||
          JSON.stringify(Object.fromEntries(await fingerprint(destination))) !== JSON.stringify(manifest.files)) {
        throw new Error('T3 Server native runtime is stale; rebuild on the target architecture');
      }
    } else {
      // 先完整构建并校验新闭包，再移动旧生成目录；失败时不会发布半套依赖。
      if (await exists(destination)) await rename(destination, join(stage, 'previous-node_modules'));
      try { await rename(join(stage, 'node_modules'), destination); }
      catch (error) {
        if (await exists(join(stage, 'previous-node_modules'))) await rename(join(stage, 'previous-node_modules'), destination);
        throw error;
      }
      await writeFile(manifestPath, manifestText);
    }
    console.log(`T3 native runtime ${check ? 'verified' : 'staged'} (${packages.size} packages; ${process.platform}-${process.arch})`);
  } finally {
    execFileSync('trash', [stage]);
  }
}
export const plugin = { name: 'pimac-native-backend', setup(builder) {
  builder.onResolve({ filter: /^@t3tools\// }, async args => {
    const [name, ...rest] = args.path.slice('@t3tools/'.length).split('/');
    const pkg = join(upstream, 'packages', name);
    const manifest = JSON.parse(await readFile(join(pkg, 'package.json'), 'utf8'));
    const spec = manifest.exports[rest.length ? `./${rest.join('/')}` : '.'];
    return { path: resolve(pkg, typeof spec === 'string' ? spec : spec.import) };
  });
  builder.onResolve({ filter: /^effect-(acp|codex-app-server)\// }, async args => {
    const [name, ...rest] = args.path.split('/');
    const pkg = join(upstream, 'packages', name);
    const manifest = JSON.parse(await readFile(join(pkg, 'package.json'), 'utf8'));
    const spec = manifest.exports['./' + rest.join('/')];
    return { path: resolve(pkg, typeof spec === 'string' ? spec : spec.import) };
  });
  builder.onResolve({ filter: /^pimac:/ }, args => ({ path: join(root, args.path.slice(6) + (/\.(?:mjs|ts)$/.test(args.path) ? '' : '.mjs')) }));
  builder.onResolve({ filter: /^[^./]/ }, args => runtimePackages.some(name => args.path === name || args.path.startsWith(name + '/'))
    ? { path: args.path, external: true } : undefined);
  builder.onResolve({ filter: /^@opencode\// }, args => ({ path: fileURLToPath(import.meta.resolve(args.path)) }));
  builder.onResolve({ filter: /^(effect|@effect\/[^/]+|jose|yaml|diff|proper-lockfile|stream-chain|stream-json|yauzl|@noble\/[^/]+)(\/.*)?$/ }, args => ({ path: require.resolve(args.path) }));
  builder.onLoad({ filter: /\.ts$/ }, async args => {
    if (!args.path.startsWith(upstream)) return;
    const file = args.path.slice(upstream.length + 1);
    let contents = await readFile(args.path, 'utf8');
    for (const patch of patches[file] ?? []) {
      if (contents.split(patch.oldText).length !== (patch.count ?? 1) + 1) throw new Error(`Ambiguous or missing upstream patch: ${file}`);
      contents = contents.replaceAll(patch.oldText, patch.newText);
    }
    return { contents, loader: 'ts', resolveDir: dirname(args.path) };
  });
} };
const result = await build({ absWorkingDir: root, entryPoints: [join(root, 'server.mjs')], bundle: true, platform: 'node', target: 'node24', format: 'esm',
  // Effect's cyclic modules produce unstable initializer elimination when both
  // orchestration paths are bundled. Preserve initializers for reproducible builds.
  write: false, treeShaking: false, minify: true, plugins: [plugin], banner: { js: '// Pinned official T3 Server with all official provider drivers and native runtime. See T3-SERVER-LICENSE.txt.\nimport {createRequire as __createRequire} from "node:module"; const require=__createRequire(import.meta.url);' },
  define: { __T3CODE_BUILD_RELAY_URL__: '"https://relay.t3.codes"', __T3CODE_BUILD_CLERK_PUBLISHABLE_KEY__: '"pk_live_Y2xlcmsudDMuY29kZXMk"', __T3CODE_BUILD_CLERK_CLI_OAUTH_CLIENT_ID__: '"hzxSgY2cH10sDU2r"' },
});
const out = resolve(root, '../../Sources/PiMacApp/Resources/t3-bridge/vendor/t3-server.mjs');
await mkdir(dirname(out), { recursive: true });
await stageRuntime(dirname(out), process.argv.includes('--check'));
if (process.argv.includes('--check')) {
  if (!Buffer.from(await readFile(out)).equals(result.outputFiles[0].contents)) throw new Error('T3 Server bundle is stale');
} else {
  await mkdir(dirname(out), { recursive: true }); await writeFile(out, result.outputFiles[0].contents);
  await writeFile(join(dirname(out), 'T3-SERVER-LICENSE.txt'), await readFile(join(upstream, 'LICENSE')));
}
console.log(`T3 Server ${process.argv.includes('--check') ? 'verified' : 'built'} (${result.outputFiles[0].contents.length} bytes; ${Object.keys(pin.files).length} pinned files)`);
