// Restore only the original files in the committed SHA-256 manifest.
import { readFile, lstat, mkdtemp, mkdir, rename, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const pin = JSON.parse(await readFile(join(root, 'upstream-pin.json'), 'utf8'));
if (pin.repository !== 'https://github.com/pingdotgg/t3code' || !/^[a-f0-9]{40}$/.test(pin.commit)) throw new Error('Invalid upstream pin');
const files = Object.entries(pin.files);
for (const [file, hash] of files) {
  if (!/^[A-Za-z0-9_./-]+$/.test(file) || file.startsWith('/') || file.split('/').some(part => !part || part === '..' || part === '.') || !/^[a-f0-9]{64}$/.test(hash)) throw new Error('Invalid pinned file');
}
async function verify(directory) {
  if (!(await lstat(directory)).isDirectory()) throw new Error('Unsafe upstream directory');
  for (const [file, hash] of files) {
    const name = join(directory, file);
    if (!(await lstat(name)).isFile() || createHash('sha256').update(await readFile(name)).digest('hex') !== hash) throw new Error(`Changed upstream file: ${file}`);
  }
}
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { maxBuffer: 128 * 1024 * 1024, ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.status})`);
  return result.stdout;
}
const target = join(root, 'upstream');
let exists = false;
try { await lstat(target); exists = true; } catch (error) { if (error.code !== 'ENOENT') throw error; }
if (exists) {
  // Never overwrite local changes or silently repair a corrupt cache.
  await verify(target);
} else {
  const args = process.argv.slice(2);
  if (args.length && (args.length !== 2 || args[0] !== '--source')) throw new Error('Usage: node fetch-upstream.mjs [--source LOCAL_GIT_CHECKOUT]');
  const temporary = await mkdtemp(join(root, '.upstream-'));
  try {
    let repository = args.length ? resolve(args[1]) : join(temporary, 'checkout');
    if (!args.length) {
      run('git', ['init', '--quiet', repository]);
      run('git', ['-C', repository, 'fetch', '--quiet', '--depth=1', pin.repository, pin.commit], { stdio: ['ignore', 'pipe', 'inherit'] });
    }
    const source = join(temporary, 'source'); await mkdir(source);
    const archive = run('git', ['-C', repository, 'archive', '--format=tar', pin.commit, '--', ...files.map(([file]) => file)]);
    run('tar', ['-xf', '-', '-C', source], { input: archive });
    await verify(source);
    await rename(source, target);
  } finally { await rm(temporary, { recursive: true, force: true }); }
}
console.log(`T3 upstream verified (${pin.commit}; ${files.length} files)`);
