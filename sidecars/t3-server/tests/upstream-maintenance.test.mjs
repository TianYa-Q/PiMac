import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';

const root = new URL('../', import.meta.url);
const pin = JSON.parse(await readFile(new URL('upstream-pin.json', root), 'utf8'));
const patches = JSON.parse(await readFile(new URL('patches.json', root), 'utf8'));

test('every pinned upstream file is pristine and every host patch still matches', async () => {
  for (const [file, expected] of Object.entries(pin.files)) {
    const content = await readFile(new URL('upstream/' + file, root));
    assert.equal(createHash('sha256').update(content).digest('hex'), expected, file);
  }
  // Include patches in modules that bundling may not currently visit.
  for (const [file, entries] of Object.entries(patches)) {
    assert(Object.hasOwn(pin.files, file), `Unpinned patch: ${file}`);
    let content = await readFile(new URL('upstream/' + file, root), 'utf8');
    for (const entry of entries) {
      assert.equal(content.split(entry.oldText).length - 1, entry.count ?? 1, file);
      content = content.replaceAll(entry.oldText, entry.newText);
    }
  }
});

test('Pi lifecycle stays upstream-owned with a bounded telemetry-only exception', () => {
  const adapter = 'apps/server/src/orchestration-v2/Adapters/PiAdapterV2.ts';
  const contract = 'packages/contracts/src/orchestrationV2.ts';
  for (const file of Object.keys(patches)) {
    assert(!file.startsWith('packages/contracts/') || file === contract, file);
    assert(!/\/Pi(?:AdapterV2|Rpc|Driver)\.ts$/.test(file) || file === adapter, file);
  }
  assert.equal(patches[adapter].length, 6);
  assert.equal(patches[contract].length, 1);
  assert(patches[contract][0].newText.includes('piMetrics: Schema.optional'));
  for (const entry of patches[adapter]) {
    assert(/pi-turn-usage|startPiMessage|recordPiDelta|endPiMessage|piTurnMetrics|metrics\.turnTokenUsage/.test(entry.newText));
    assert(!/connection\.terminate|state\.activeTurn\s*=|request\(|type: "prompt"/.test(entry.newText));
  }
  // The host allowlist supplements the official connection-scoped middleware;
  // it must not resurrect ws.ts's retired per-handler scope checks.
  assert(Object.hasOwn(patches, 'apps/server/src/auth/RpcAuthorization.ts'));
  for (const entry of patches['apps/server/src/ws.ts']) {
    assert(!entry.newText.includes('authorizeEffect(requiredScopeForRpcMethod'));
    assert(!entry.newText.includes('authorizeStream(requiredScopeForRpcMethod'));
  }
});
