import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, stat, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { enableCodemode, updateSettings } from '../../scripts/enable-codemode.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-code-config-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  return join(directory, 'settings.json');
}

test('adds to inherited defaults and preserves unrelated settings', () => {
  const settings = { defaultTools: ['-bash', '+powershell'], packages: ['local-extension'], codemode: { inlineBudget: 1000 } };
  const next = enableCodemode(settings);
  assert.deepEqual(next.defaultTools, ['-bash', '+powershell', '+codemode']);
  assert.deepEqual(next.packages, settings.packages);
  assert.deepEqual(next.codemode, { mode: 'on', inlineBudget: 1000 });
  assert.deepEqual(settings.defaultTools, ['-bash', '+powershell']);
  assert.deepEqual(enableCodemode({}).defaultTools, ['+codemode']);
});

test('explicit allowlists and empty lists are not widened to the default tools', () => {
  assert.deepEqual(enableCodemode({ defaultTools: ['read', 'grep', '-codemode'] }).defaultTools, ['read', 'grep', 'codemode']);
  assert.deepEqual(enableCodemode({ defaultTools: [] }).defaultTools, ['codemode']);
  const only = enableCodemode({ defaultTools: ['codemode', '+codemode'], codemode: { mode: 'only' } });
  assert.deepEqual(only.defaultTools, ['codemode']);
  assert.equal(only.codemode.mode, 'only');
  assert.deepEqual(enableCodemode(only), only);
});

test('atomic update backs up original bytes once with private permissions', async t => {
  const file = await fixture(t);
  const original = '{"defaultModel":"custom-model","packages":["local-package"]}\n';
  await writeFile(file, original);
  const first = await updateSettings(file);
  assert.equal(first.changed, true);
  assert.equal(await readFile(first.backup, 'utf8'), original);
  assert.equal((await stat(first.backup)).mode & 0o777, 0o600);
  const parsed = JSON.parse(await readFile(file, 'utf8'));
  assert.equal(parsed.defaultModel, 'custom-model');
  assert.deepEqual(parsed.packages, ['local-package']);
  assert.deepEqual(await updateSettings(file), { changed: false });
});

test('invalid JSON or schema is never replaced by an empty configuration', async t => {
  const file = await fixture(t);
  for (const value of ['{broken', '{"defaultTools":null}', '{"codemode":[]}']) {
    await writeFile(file, value);
    await assert.rejects(updateSettings(file));
    assert.equal(await readFile(file, 'utf8'), value);
  }
});

test('symlink configuration is not replaced by a regular file', async t => {
  const file = await fixture(t);
  const target = file + '.target';
  await writeFile(target, '{}');
  await symlink(target, file);
  await assert.rejects(updateSettings(file));
  assert.equal(await readFile(target, 'utf8'), '{}');
});
