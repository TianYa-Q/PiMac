// Enable official Pi codemode without replacing the user's selected tools or other settings.
// Run: node scripts/enable-codemode.mjs [path/to/settings.json]
import { readFile, writeFile, rename, unlink, mkdir, lstat, copyFile, chmod } from 'node:fs/promises';
import { constants } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { homedir } from 'node:os';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export function enableCodemode(settings) {
  if (!settings || typeof settings !== 'object' || Array.isArray(settings)) throw new Error('Settings must be an object');
  const tools = settings.defaultTools;
  if (tools !== undefined && (!Array.isArray(tools) || tools.some(x => typeof x !== 'string'))) {
    throw new Error('defaultTools must be a string array');
  }
  const next = { ...settings };
  // Preserve explicit allowlists, including []. +/- lists retain inherited defaults.
  const explicit = tools !== undefined && (tools.length === 0 || tools.some(x => !/^[+-]/.test(x)));
  const selected = (tools ?? []).filter(x => !['codemode', '+codemode', '-codemode'].includes(x));
  next.defaultTools = [...selected, explicit ? 'codemode' : '+codemode'];
  if (settings.codemode !== undefined &&
      (!settings.codemode || typeof settings.codemode !== 'object' || Array.isArray(settings.codemode))) {
    throw new Error('codemode must be an object');
  }
  next.codemode = { mode: 'on', ...settings.codemode };
  return next;
}

export async function updateSettings(file) {
  let text;
  let mode = 0o600;
  try {
    const info = await lstat(file);
    if (!info.isFile()) throw new Error('Settings must be a regular file; pass a symlink target explicitly');
    text = await readFile(file, 'utf8');
    mode = info.mode & 0o777;
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const settings = text === undefined ? {} : JSON.parse(text);
  const next = enableCodemode(settings);
  if (JSON.stringify(next) === JSON.stringify(settings)) return { changed: false };
  await mkdir(dirname(file), { recursive: true, mode: 0o700 });
  const backup = text === undefined ? undefined : `${file}.before-codemode-${randomUUID()}.bak`;
  if (backup) {
    await copyFile(file, backup, constants.COPYFILE_EXCL);
    await chmod(backup, 0o600);
  }
  const temp = `${file}.${randomUUID()}.tmp`;
  try {
    await writeFile(temp, JSON.stringify(next, null, 2) + '\n', { mode, flag: 'wx' });
    await rename(temp, file);
  } finally { await unlink(temp).catch(() => {}); }
  return { changed: true, backup };
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  const file = resolve(process.argv[2] ?? join(process.env.PI_CODING_AGENT_DIR ?? join(homedir(), '.pi/agent'), 'settings.json'));
  const result = await updateSettings(file);
  console.log(result.changed ? `Codemode enabled: ${file}` : `Codemode already enabled: ${file}`);
  if (result.backup) console.log(`Settings backup: ${result.backup}`);
  console.log('Restart idle Pi Mac sessions to load the new tool selection. Trusted project settings may override defaults.');
}
