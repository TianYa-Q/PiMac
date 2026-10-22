import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';

const root = new URL('../', import.meta.url);
const pin = JSON.parse(await readFile(new URL('upstream-pin.json', root), 'utf8'));
const patches = JSON.parse(await readFile(new URL('patches.json', root), 'utf8'));

test('MCP catalog and delegation keep official provider and target semantics without host patches', () => {
  assert(!Object.hasOwn(patches, 'apps/server/src/mcp/OrchestratorMcpService.ts'),
    'Do not filter the official MCP catalog or restrict explicit provider/model targets');
});

test('native provider SDKs, terminal and workspace search have no host disabling patches', () => {
  for (const file of [
    'apps/server/src/provider/builtInDrivers.ts',
    'packages/provider-cursor/src/server/sdk.ts',
    'apps/server/src/terminal/NodePtyAdapter.ts',
    'apps/server/src/workspace/WorkspaceSearchIndex.ts',
  ]) assert(!Object.hasOwn(patches, file), file);
});

test('source fetcher accepts pinned native patch filenames and verifies the cached release', async () => {
  const { stdout } = await promisify(execFile)(process.execPath, [fileURLToPath(new URL('fetch-upstream.mjs', root))]);
  assert(stdout.includes(`T3 upstream verified (${pin.commit}; ${Object.keys(pin.files).length} files)`));
});

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

test('upstream owns Pi structured image output, history parsing and project review roots', async () => {
  const usageDiscovery = patches['apps/server/src/usage/UsageService.ts'];
  assert.equal(usageDiscovery.length, 5);
  assert(usageDiscovery.some(entry => entry.newText.includes('resolveProviderInstanceEnabled(instance)')));
  assert(usageDiscovery.some(entry => entry.newText.includes('instances.length === 0 ? Effect.succeed([])')));
  assert(usageDiscovery.every(entry => !/parse|dedupe|readTranscriptRecords|fingerprint|provider ===/.test(entry.newText)),
    'Only gate usage discovery by official settings; keep parsing/aggregation driver-neutral and upstream-owned');
  assert(!Object.hasOwn(patches, 'packages/provider-pi/src/server/usage.ts'));
  const [adapter, usage, review] = await Promise.all([
    'packages/provider-pi/src/server/adapter.ts',
    'packages/provider-pi/src/server/usage.ts',
    'apps/server/src/review/ReviewService.ts',
  ].map(file => readFile(new URL('upstream/' + file, root), 'utf8')));
  assert(adapter.includes('const output = piToolOutput(resultRecord, toolName);'));
  assert(adapter.includes('return {\n    content,\n    ...(structured === undefined ? {} : { structuredContent: structured }),\n  };'));
  assert(usage.includes('provider: "pi"'));
  assert(usage.includes('dedupeKey: JSON.stringify(["pi", entry.id, entry.timestamp, model])'));
  assert(!Object.hasOwn(patches, 'apps/server/src/provider/builtInDrivers.ts'),
    'Keep the official complete provider and usage driver registries untouched');
  assert(review.includes('projectStore.listShells()'));
  assert(review.includes('managedWorktreesDirectories('));
  // 剩余 review 补丁只扩展外部活跃 worktree，不重复上游项目根查询。
  assert(patches['apps/server/src/review/ReviewService.ts'].every(entry =>
    !entry.newText.includes('projects.list()')));
});

test('Pi lifecycle and image projection stay upstream-owned with bounded telemetry, account selection and Fast exceptions', () => {
  const adapter = 'packages/provider-pi/src/server/adapter.ts';
  const contract = 'packages/contracts/src/orchestrationV2.ts';
  for (const file of Object.keys(patches)) {
    assert(!file.startsWith('packages/contracts/') || file === contract, file);
    assert(!/\/Pi(?:AdapterV2|Rpc|Driver)\.ts$/.test(file), file);
    assert(!/^packages\/provider-pi\/src\/server\/(?:adapter|rpc|driver)\.ts$/.test(file) || file === adapter, file);
  }
  assert(!patches[adapter].some(entry => entry.newText.includes('toolOutputImages')),
    'Structured tool output and image preservation are now official upstream behavior');
  const fastPatches = patches[adapter].filter(entry => entry.newText.includes("fastStatus"));
  assert.equal(fastPatches.length, 2);
  assert(fastPatches.some(entry => entry.newText.includes('Fast mode not confirmed')));
  assert.equal(patches[adapter].length - fastPatches.length, 7);
  const selection = patches[adapter].filter(entry => entry.newText.includes('accountSelections.record'));
  assert.equal(selection.length, 1);
  assert(selection[0].newText.includes('state?.providerThread.appThreadId ?? input.threadId'));
  assert.equal(patches[contract].length, 3);
  assert.equal(patches[contract].filter(entry => entry.newText.includes("latestMessageAt: Schema.optional")).length, 2);
  assert(patches[contract].some(entry => entry.newText.includes('piMetrics: Schema.optional')));
  for (const entry of patches[adapter].filter(entry => !fastPatches.includes(entry))) {
    assert(/pi-turn-usage|startPiMessage|recordPiDelta|endPiMessage|piTurnMetrics|metrics\.turnTokenUsage|accountSelections\.record/.test(entry.newText));
    assert(!/connection\.terminate|state\.activeTurn\s*=|request\(|type: "prompt"/.test(entry.newText));
  }
  const discovery = patches['packages/provider-pi/src/server/status.ts'];
  assert(discovery.every(entry =>
    /createModelContextSettings|PiThinkingDefaults|defaults\.modelLevels/.test(entry.newText)),
    'Pi discovery patches only retain model context and project effective thinking defaults');
  assert(discovery.some(entry => entry.newText.includes('.recordModels(modelsData)')));
  assert(discovery.every(entry => !/\.set\(|connection\.|type: "prompt"/.test(entry.newText)));
  // RPC 补丁只添加诊断，不改变官方 scope 判定或恢复旧版逐 handler 授权。
  const authorization = patches['apps/server/src/auth/RpcAuthorization.ts'];
  assert(authorization.some(entry => entry.newText.includes('requiredScopesForRpcCall(rpc._tag, payload)')));
  assert(authorization.some(entry => entry.newText.includes('requiredScopes.find((scope) => !scopes.includes(scope))')));
  for (const entry of patches['apps/server/src/ws.ts']) {
    assert(!entry.newText.includes('authorizeEffect(requiredScopeForRpcMethod'));
    assert(!entry.newText.includes('authorizeStream(requiredScopeForRpcMethod'));
  }
});
