import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { migrateProviderDiscoverySettings } from '../settings-migration.mjs';

const defaults = { pi: { driver: 'pi', enabled: true, config: { binaryPath: 'pi' } },
  codex: { driver: 'codex', enabled: false }, claudeAgent: { driver: 'claudeAgent', enabled: false } };
function fixture(t, text) {
  const root = new URL('../../../tmp/', import.meta.url);
  fs.mkdirSync(root, { recursive: true });
  const directory = fs.mkdtempSync(path.join(root.pathname, 'provider-discovery-'));
  t.after(() => execFileSync('trash', [directory]));
  const file = path.join(directory, 'settings.json');
  fs.writeFileSync(file, text, { mode: 0o600 });
  return file;
}

test('implicit builtins become disabled settings, without altering Pi or native capability settings', t => {
  const original = { providerInstances: { pi: { driver: 'pi', config: { binaryPath: '/custom/pi' } } },
    defaultRuntimeMode: 'full-access', enableAgentBrowserAccess: true, customFutureSetting: { keep: true },
    textGenerationModelSelection: { instanceId: 'pi', model: 'custom/title-model' } };
  const text = JSON.stringify(original);
  const file = fixture(t, text);
  migrateProviderDiscoverySettings(file, defaults);
  const settings = JSON.parse(fs.readFileSync(file));
  assert.deepEqual(settings.providerInstances, { ...defaults, pi: original.providerInstances.pi });
  assert.deepEqual({ ...settings, providerInstances: original.providerInstances }, original);
  assert.equal(fs.readFileSync(file + '.before-pi-discovery-v1', 'utf8'), text);
  for (const suffix of ['', '.before-pi-discovery-v1', '.pi-discovery-v1']) {
    assert.equal(fs.statSync(file + suffix).mode & 0o077, 0);
  }
});

test('one-time preference disables explicit nonPi and project overrides, preserving every config and future edits', t => {
  const original = { providerInstances: {
    pi: { driver: 'pi', enabled: false, config: { launchArgs: '--offline' } },
    work: { driver: 'codex', enabled: true, displayName: 'Work', config: { binaryPath: '/custom/codex' },
      environment: [{ name: 'CODEX_HOME', value: '/private/work' }] },
    future: { driver: 'thirdParty', config: { secretReference: 'keep' } },
  }, projectSettingsOverrides: { project: { defaultRuntimeMode: 'full-access', providerInstances: {
    work: { enabled: true }, pi: { enabled: true }, future: { enabled: true },
  } } } };
  const file = fixture(t, JSON.stringify(original));
  migrateProviderDiscoverySettings(file, defaults);
  const settings = JSON.parse(fs.readFileSync(file));
  assert.deepEqual(settings.providerInstances.work, { ...original.providerInstances.work, enabled: false });
  assert.deepEqual(settings.providerInstances.future, { ...original.providerInstances.future, enabled: false });
  assert.deepEqual(settings.providerInstances.pi, original.providerInstances.pi);
  assert.deepEqual(settings.projectSettingsOverrides.project, { defaultRuntimeMode: 'full-access', providerInstances: {
    work: { enabled: false }, pi: { enabled: true }, future: { enabled: false },
  } });
  settings.providerInstances.work.enabled = true;
  settings.projectSettingsOverrides.project.providerInstances.future.enabled = true;
  delete settings.providerInstances.codex; // Removing an official default slot is also a user choice.
  const edited = JSON.stringify(settings);
  fs.writeFileSync(file, edited);
  migrateProviderDiscoverySettings(file, defaults);
  assert.equal(fs.readFileSync(file, 'utf8'), edited);
});

test('legacy provider blobs populate disabled defaults without losing config or overriding explicit instances', t => {
  const providers = {
    pi: { enabled: false, binaryPath: '/custom/pi', launchArgs: '--offline' },
    codex: { enabled: true, binaryPath: '/custom/codex', binaryArgs: ['--profile', 'work'],
      modelOptions: [{ id: 'reasoning', value: 'high' }], nested: { futureOption: [false, 0, ''] } },
    claudeAgent: { enabled: true, binaryPath: '/custom/claude', environment: { HOME: '/private/claude' },
      options: { permissions: 'keep-exactly' } },
  };
  const file = fixture(t, JSON.stringify({ providers }));
  migrateProviderDiscoverySettings(file, defaults);
  const settings = JSON.parse(fs.readFileSync(file));
  for (const [driver, legacy] of Object.entries(providers)) {
    const { enabled, ...config } = legacy;
    assert.deepEqual(settings.providerInstances[driver], { driver, enabled: false, config });
  }
  assert.deepEqual(settings.providers, providers); // 上游仍负责清理旧 map。
  const explicit = { driver: 'codex', enabled: true, config: { binaryPath: '/new/codex', options: ['new'] } };
  const second = fixture(t, JSON.stringify({ providers, providerInstances: { codex: explicit } }));
  migrateProviderDiscoverySettings(second, defaults);
  assert.deepEqual(JSON.parse(fs.readFileSync(second)).providerInstances.codex, { ...explicit, enabled: false });
});

test('fresh Pi-only defaults are marked once and an interrupted backup is retried, not treated as completion', t => {
  const file = fixture(t, JSON.stringify({ providerInstances: defaults }));
  fs.writeFileSync(file + '.before-pi-discovery-v1', 'original pre-crash backup', { mode: 0o600 });
  migrateProviderDiscoverySettings(file, defaults);
  assert.deepEqual(JSON.parse(fs.readFileSync(file)).providerInstances, defaults);
  assert.equal(fs.readFileSync(file + '.before-pi-discovery-v1', 'utf8'), 'original pre-crash backup');
  assert.equal(fs.readFileSync(file + '.pi-discovery-v1', 'utf8'), '1\n');
});

test('malformed settings fail without a migration marker or partial writes', t => {
  for (const text of ['null', '[]', '{', '{"providerInstances":[]}', '{"providerInstances":{"bad":null}}',
    '{"projectSettingsOverrides":{"project":{"providerInstances":{"codex":null}}}}']) {
    const file = fixture(t, text);
    assert.throws(() => migrateProviderDiscoverySettings(file, defaults));
    assert.equal(fs.readFileSync(file, 'utf8'), text);
    assert.equal(fs.existsSync(file + '.pi-discovery-v1'), false);
    assert.equal(fs.existsSync(file + '.before-pi-discovery-v1'), false);
  }
  const file = fixture(t, '{}');
  fs.writeFileSync(file + '.pi-discovery-v1', 'corrupt');
  assert.throws(() => migrateProviderDiscoverySettings(file, defaults), /Invalid.*marker/);
});
