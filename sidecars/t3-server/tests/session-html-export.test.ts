import assert from 'node:assert/strict';
import test from 'node:test';
import { mkdir, mkdtemp, writeFile, chmod, readFile, rename, access } from 'node:fs/promises';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createServerGateway } from './fixtures/protocol-server.mjs';
import { call } from '../generated/client.mjs';
import { exportPiSessionHtml } from '../pi-session-html.ts';

const root = new URL('../../../tmp/pi-html-export/', import.meta.url).pathname;

test('HTML export restores a persisted Pi conversation after Server restart without a model turn', async t => {
  await mkdir(root, { recursive: true });
  const directory = await mkdtemp(join(root, 'server-'));
  const binary = join(directory, 'fixture-pi');
  await writeFile(binary, `#!/bin/sh\nexec '${process.execPath}' '${new URL('./fixtures/pi.mjs', import.meta.url).pathname}' "$@"\n`);
  await chmod(binary, 0o700);
  let gateway: Awaited<ReturnType<typeof createServerGateway>>;
  let headers: Record<string, string>;
  t.after(async () => { await gateway?.close(); });
  const open = async () => {
    gateway = await createServerGateway({ token: 'ab'.repeat(32), directory, piConfig: { binaryPath: binary } });
    const credential = await gateway.official.management.desktopSession();
    headers = { authorization: 'Bearer ' + credential.token, 'content-type': 'application/json', 'x-t3-orchestration-protocol': '2' };
  };
  await open();
  const rpc = async (method: string, input: unknown) => {
    const result = await fetch(gateway.serverURL + '/api/auth/websocket-ticket', { method: 'POST', headers, body: '{}' });
    const ticket = await result.json();
    return call(gateway.serverURL.replace('http:', 'ws:') + '/ws?orchestrationProtocol=2&wsTicket=' + ticket.ticket, method, input);
  };
  const dispatch = (input: object) => rpc('orchestration.dispatchCommand', { commandId: randomUUID(), ...input });
  const projectId = randomUUID(), threadId = randomUUID();
  await rpc('projects.mutate', { type: 'project.create', commandId: randomUUID(), projectId, title: 'HTML export', workspaceRoot: directory });
  await dispatch({ type: 'thread.create', projectId, threadId, title: 'Export fixture', createdBy: 'user', creationSource: 'web',
    modelSelection: { instanceId: 'pi', model: 'test/model' }, runtimeMode: 'full-access', interactionMode: 'default', branch: null, worktreePath: null });
  const url = () => gateway.serverURL + '/api/orchestration/threads/' + threadId + '/export-html';
  const exportHTML = () => fetch(url(), { method: 'POST', headers, body: '{}' });
  assert.equal((await exportHTML()).status, 409, 'empty thread is not a corrupt or exportable Pi session');
  await dispatch({ type: 'message.dispatch', threadId, messageId: randomUUID(), text: 'export fixture', attachments: [],
    createdBy: 'user', creationSource: 'web', dispatchMode: { type: 'start_immediately' } });
  const snapshot = async () => (await (await fetch(gateway.serverURL + '/api/orchestration/threads/' + threadId, { headers })).json()).projection;
  let before;
  for (let attempt = 0; attempt < 200; attempt++) {
    before = await snapshot();
    if (before.runs.some((r: { status: string }) => r.status === 'completed')) break;
    await new Promise(resolve => setTimeout(resolve, 50));
  }
  assert.equal(before.runs[0].status, 'completed');
  const nativePath = before.providerThreads.find((p: { id: string }) => p.id === before.thread.activeProviderThreadId).nativeThreadRef.nativeId;
  let response = await exportHTML();
  assert.equal(response.status, 200, await response.clone().text());
  const decode = (html: string) => JSON.parse(Buffer.from(/type="application\/json">([^<]+)</.exec(html)![1]!, 'base64').toString('utf8'));
  assert.equal(decode((await response.json()).html).sessionFile, nativePath);
  await gateway.close();
  await open();
  assert.equal((await fetch(url(), { method: 'POST' })).status, 401);
  // 无效凭据和 supervisor 凭据不能绕过官方认证；恢复接口不暴露到管理 socket。
  assert.equal((await fetch(url(), { method: 'POST', headers: { authorization: 'Bearer ' + 'ab'.repeat(32) } })).status, 401);
  response = await exportHTML();
  assert.equal(response.status, 200, await response.clone().text());
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const { html } = await response.json();
  const payload = decode(html);
  assert.equal(payload.sessionFile, nativePath);
  assert.equal(payload.systemPrompt, 'Fixture restored system prompt');
  assert.deepEqual(payload.tools, [{ name: 'read' }]);
  const after = await snapshot();
  assert.equal(after.runs.length, before.runs.length);
  assert.equal(after.messages.length, before.messages.length);
  assert.equal(after.thread.activeProviderThreadId, before.thread.activeProviderThreadId);
  const records = (await readFile(join(directory, 'fixture-rpc.ndjson'), 'utf8')).trim().split('\n').map(line => JSON.parse(line));
  assert.equal(records.filter(r => r.command === 'prompt' && !r.message.startsWith('/pimac-export-context ')).length, 1, 'restoring and exporting never sends another model prompt');
  assert.equal(records.filter(r => r.command === 'export_html').length, 2);
  assert(records.some(r => r.command === 'switch_session'));
  await writeFile(join(directory, 'fixture-export-failure'), 'fail');
  assert.equal((await exportHTML()).status, 409, 'Pi failures must not become empty successful exports');
  await rename(nativePath, nativePath + '.saved');
  assert.equal((await exportHTML()).status, 409, 'missing history must never be recreated as a new session');
  await assert.rejects(access(nativePath));
});

test('native export preserves native data and safely fills the effective system prompt', async () => {
  const original = { entries: [{ id: 'one' }], tools: [{ name: 'read' }], renderedTools: { custom: 'kept' }, systemPrompt: '' };
  const system = '</script><script>alert("test")</script>\n中文 prompt';
  const html = await exportPiSessionHtml(async command => {
    await writeFile(command.outputPath, '<html><script id="session-data" type="application/json">' + Buffer.from(JSON.stringify(original)).toString('base64') + '</script></html>');
    return { path: command.outputPath };
  }, system);
  assert(!html.includes(system));
  const encoded = /type="application\/json">([^<]+)</.exec(html)![1]!;
  assert.deepEqual(JSON.parse(Buffer.from(encoded, 'base64').toString('utf8')), { ...original, systemPrompt: system });
});

test('native export refuses malformed output and propagates Pi failure', async () => {
  await assert.rejects(exportPiSessionHtml(async () => ({ path: '/arbitrary/path.html' }), 'system'), /invalid HTML export path/);
  await assert.rejects(exportPiSessionHtml(async () => { throw new Error('Pi failed'); }, 'system'), /Pi failed/);
  await assert.rejects(exportPiSessionHtml(async command => {
    await writeFile(command.outputPath, '');
    return { path: command.outputPath };
  }, 'system'), /empty or exceeds/);
  await assert.rejects(exportPiSessionHtml(async command => {
    await writeFile(command.outputPath, '<html>unsupported template</html>');
    return { path: command.outputPath };
  }, 'system'), /Unsupported Pi HTML export template/);
});
