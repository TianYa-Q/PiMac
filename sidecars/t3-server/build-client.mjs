import { build } from 'esbuild';
import { plugin } from './build.mjs';
for (const [entry, output] of [['client.mjs', 'client.mjs']]) {
  await build({ entryPoints: [new URL('./' + entry, import.meta.url).pathname], outfile: new URL('./generated/' + output, import.meta.url).pathname,
    bundle: true, platform: 'node', target: 'node24', format: 'esm', minify: true, plugins: [plugin] });
}
