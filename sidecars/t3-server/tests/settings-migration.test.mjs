import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { migratePiSettings } from '../settings-migration.mjs';

test('obsolete Pi launch arguments migrate once, preserving user configuration and an exact backup', t => {
  const directory = mkdtempSync(join(tmpdir(), 'pimac-pi-settings-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const file = join(directory, 'settings.json');
  const settings = { defaultRuntimeMode: 'full-access', providerInstances: { pi: { driver: 'pi', enabled: true,
    config: { binaryPath: 'old-pi', binaryArgs: ['--extension', '/app/pimac-fast.ts', '--extension', '/app/pimac-compaction.ts', '--extension', "/user/it's custom.ts"] } },
    other: { driver: 'codex', enabled: false, config: {} } } };
  const original = JSON.stringify(settings);
  writeFileSync(file, original, { mode: 0o600 });
  migratePiSettings(file, { binaryPath: 'new-pi' });
  const migrated = JSON.parse(readFileSync(file, 'utf8'));
  assert.equal(migrated.providerInstances.pi.config.binaryPath, 'new-pi');
  assert.equal(migrated.providerInstances.pi.config.binaryArgs, undefined);
  assert.equal(migrated.providerInstances.pi.config.launchArgs, "'--extension' '/user/it'\\''s custom.ts'");
  assert.deepEqual(migrated.providerInstances.other, settings.providerInstances.other);
  assert.equal(readFileSync(file + '.before-official-pi', 'utf8'), original);
  assert.equal(statSync(file + '.before-official-pi').mode & 0o077, 0);
  const once = readFileSync(file, 'utf8');
  migratePiSettings(file, { binaryPath: 'ignored' });
  assert.equal(readFileSync(file, 'utf8'), once);
});

test('already-official launch configuration is untouched', t => {
  const directory = mkdtempSync(join(tmpdir(), 'pimac-pi-current-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const file = join(directory, 'settings.json');
  const original = '{"providerInstances":{"pi":{"driver":"pi","config":{"launchArgs":"--offline"}}}}';
  writeFileSync(file, original, { mode: 0o600 });
  migratePiSettings(file, {});
  assert.equal(readFileSync(file, 'utf8'), original);
});
