import { readFile, readdir, mkdir, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const directory = path.dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);
const dependency = path.dirname(require.resolve('katex/package.json'));
const manifest = JSON.parse(await readFile(path.join(directory, 'package.json'), 'utf8'));
const installed = JSON.parse(await readFile(path.join(dependency, 'package.json'), 'utf8'));
if (installed.version !== manifest.dependencies.katex) {
  throw new Error('KaTeX version mismatch; run npm ci in sidecars/math-rendering');
}
const destination = path.resolve(directory, '../../Sources/PiMacApp/Resources/KaTeX');
const files = new Map<string, Buffer>();
for (const name of ['katex.min.js', 'katex.min.css']) {
  files.set(name, await readFile(path.join(dependency, 'dist', name)));
}
files.set('LICENSE', await readFile(path.join(dependency, 'LICENSE')));
// 保留完整字体集，CSS 的所有格式回退均可离线使用；先读完依赖再写资源，失败不能冒充成功。
for (const name of await readdir(path.join(dependency, 'dist/fonts'))) {
  if (!/^[\w-]+\.(woff2?|ttf)$/.test(name)) throw new Error(`Unexpected KaTeX font: ${name}`);
  files.set(`fonts/${name}`, await readFile(path.join(dependency, 'dist/fonts', name)));
}
for (const [name, data] of files) {
  const target = path.join(destination, name);
  let previous: Buffer | undefined;
  try {
    previous = await readFile(target);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== 'ENOENT') throw error;
  }
  // 内容不变不触碰 mtime，避免重复准备导致 SwiftPM 重新拷贝整套资源。
  if (previous?.equals(data)) continue;
  await mkdir(path.dirname(target), { recursive: true });
  await writeFile(target, data);
}
console.log(`Prepared offline KaTeX ${installed.version}: ${files.size} resources`);
