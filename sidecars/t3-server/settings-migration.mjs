import fs from 'node:fs';

// Only migrate Pi Mac's obsolete launch configuration. Upstream owns SQLite
// schema/history migration. Never rewrite native session files or thread IDs.
export function migratePiSettings(file, piConfig) {
  if (!fs.existsSync(file)) return;
  const text = fs.readFileSync(file, 'utf8');
  const settings = JSON.parse(text);
  const instance = settings.providerInstances?.pi;
  if (!instance || instance.driver !== 'pi' || !Array.isArray(instance.config?.binaryArgs)) return;
  const config = { ...instance.config };
  // These host-injected extensions belonged to the retired adapter. Do not
  // inject them into official Pi. User-installed extensions still load normally.
  const args = config.binaryArgs;
  const retained = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--extension' && /(?:^|\/)pimac-(?:fast|compaction)\.ts$/.test(args[i + 1] ?? '')) { i++; continue; }
    retained.push(args[i]);
  }
  if (!retained.every(arg => typeof arg === 'string')) throw new Error('Invalid legacy Pi arguments');
  delete config.binaryArgs;
  config.launchArgs ??= retained.map(arg => "'" + arg.replaceAll("'", "'\\''") + "'").join(' ');
  // A fresh host binary selection takes precedence, without resetting user settings.
  if (piConfig.binaryPath) config.binaryPath = piConfig.binaryPath;
  instance.config = config;
  const backup = file + '.before-official-pi';
  if (!fs.existsSync(backup)) fs.writeFileSync(backup, text, { mode: 0o600, flag: 'wx' });
  const temporary = file + '.official-pi.tmp';
  fs.writeFileSync(temporary, JSON.stringify(settings, null, 2) + '\n', { mode: 0o600, flag: 'wx' });
  fs.renameSync(temporary, file);
}
