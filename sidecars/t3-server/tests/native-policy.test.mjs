import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

test('host does not replace official authorization or capability declarations', async () => {
  const root = new URL('../', import.meta.url);
  const native = await readFile(new URL('native.mjs', root), 'utf8');
  const management = await readFile(new URL('management.mjs', root), 'utf8');
  const patches = JSON.parse(await readFile(new URL('patches.json', root), 'utf8'));
  assert.doesNotMatch(native, /rpcAllowed|httpAllowed|nativeCapabilities/);
  assert.doesNotMatch(management, /httpAllowed|localControl/);
  const authorization = patches['apps/server/src/auth/RpcAuthorization.ts'];
  assert(authorization.every(entry => !/rpcAllowed|allowed &&|PiNative/.test(entry.newText)));
  assert(authorization.some(entry => entry.newText.includes('authorized ? effect : Effect.fail(rpcAuthorizationError(requiredScope))')));
  assert(patches['apps/server/src/environment/ServerEnvironment.ts'].every(entry =>
    !/nativeCapabilities|capabilities: \{/.test(entry.newText)));
  const lan = await readFile(new URL('../../../Sources/PiMacApp/Resources/t3-bridge/lan-listener.mjs', import.meta.url), 'utf8');
  assert.doesNotMatch(lan, /allowed\(req|api\/connect\/unlink/);
});
