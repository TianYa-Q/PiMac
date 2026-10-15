import fs from 'node:fs';

// Migrate Pi Mac's launch/discovery preferences only. Upstream owns SQLite
// schema/history migration. Never rewrite native session files or thread IDs.
const isRecord = value => value !== null && typeof value === 'object' && !Array.isArray(value);

export function migrateProviderDiscoverySettings(file, defaults) {
  const marker = file + '.pi-discovery-v1';
  try {
    if (fs.readFileSync(marker, 'utf8') !== '1\n') throw new Error('Invalid provider discovery migration marker');
    return;
  } catch (error) { if (error.code !== 'ENOENT') throw error; }
  const text = fs.readFileSync(file, 'utf8');
  const settings = JSON.parse(text);
  if (!isRecord(settings) || (settings.providerInstances !== undefined && !isRecord(settings.providerInstances)) ||
      (settings.projectSettingsOverrides !== undefined && !isRecord(settings.projectSettingsOverrides))) {
    throw new Error('Invalid provider discovery settings');
  }
  const instances = { ...defaults, ...settings.providerInstances };
  for (const [id, instance] of Object.entries(instances)) {
    if (!isRecord(instance) || typeof instance.driver !== 'string') throw new Error('Invalid provider instance: ' + id);
    // 这是一次性的单用户发现偏好，不删除驱动、配置或运行入口；之后完全服从官方设置。
    if (instance.driver !== 'pi') instances[id] = { ...instance, enabled: false };
  }
  for (const overrides of Object.values(settings.projectSettingsOverrides ?? {})) {
    if (!isRecord(overrides) || (overrides.providerInstances !== undefined && !isRecord(overrides.providerInstances))) {
      throw new Error('Invalid project provider overrides');
    }
    for (const [id, override] of Object.entries(overrides.providerInstances ?? {})) {
      if (!isRecord(override)) throw new Error('Invalid project provider override: ' + id);
      if (instances[id]?.driver !== 'pi' && override.enabled === true) override.enabled = false;
    }
  }
  settings.providerInstances = instances;
  const backup = file + '.before-pi-discovery-v1';
  try { fs.writeFileSync(backup, text, { mode: 0o600, flag: 'wx' }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  // 备份不能充当完成标记：若在 rename 前崩溃，下次仍需迁移。完成后才写标记，
  // 确保用户以后手动启用其他实例不会在每次启动时被静默重置。
  const temporary = file + '.pi-discovery.tmp';
  fs.writeFileSync(temporary, JSON.stringify(settings, null, 2) + '\n', { mode: 0o600 });
  fs.renameSync(temporary, file);
  fs.writeFileSync(marker, '1\n', { mode: 0o600, flag: 'wx' });
}

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
