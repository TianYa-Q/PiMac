import { build } from 'esbuild';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, resolve, join } from 'node:path';
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
  builder.onResolve({ filter: /^pimac:/ }, args => ({ path: join(root, args.path.slice(6) + (args.path.endsWith('.mjs') ? '' : '.mjs')) }));
  builder.onResolve({ filter: /^(node-pty|@ff-labs\/fff-node|@napi-rs\/keyring|@anthropic-ai\/claude-agent-sdk|@opencode-ai\/sdk)(\/.*)?$/ }, args => ({ path: args.path, namespace: 'disabled-native' }));
  builder.onLoad({ filter: /.*/, namespace: 'disabled-native' }, () => ({ contents: `const unavailable=()=>{throw new Error('Disabled in the Pi Mac host')}; export default {spawn:unavailable}; export {unavailable as spawn,unavailable as query,unavailable as Entry,unavailable as createOpencodeClient,unavailable as createOpencodeServer,unavailable as forkSession,unavailable as getSubagentMessages};`, loader: 'js' }));
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
  write: false, treeShaking: false, minify: true, plugins: [plugin], banner: { js: '// Pinned official T3 Server with its native Pi driver and Pi Mac host policy. See T3-SERVER-LICENSE.txt.\nimport {createRequire as __createRequire} from "node:module"; const require=__createRequire(import.meta.url);' },
  define: { __T3CODE_BUILD_RELAY_URL__: '"https://relay.t3.codes"', __T3CODE_BUILD_CLERK_PUBLISHABLE_KEY__: '"pk_live_Y2xlcmsudDMuY29kZXMk"', __T3CODE_BUILD_CLERK_CLI_OAUTH_CLIENT_ID__: '"hzxSgY2cH10sDU2r"' },
});
const out = resolve(root, '../../Sources/PiMacApp/Resources/t3-bridge/vendor/t3-server.mjs');
if (process.argv.includes('--check')) {
  if (!Buffer.from(await readFile(out)).equals(result.outputFiles[0].contents)) throw new Error('T3 Server bundle is stale');
} else {
  await mkdir(dirname(out), { recursive: true }); await writeFile(out, result.outputFiles[0].contents);
  await writeFile(join(dirname(out), 'T3-SERVER-LICENSE.txt'), await readFile(join(upstream, 'LICENSE')));
}
console.log(`T3 Server ${process.argv.includes('--check') ? 'verified' : 'built'} (${result.outputFiles[0].contents.length} bytes; ${Object.keys(pin.files).length} pinned files)`);
