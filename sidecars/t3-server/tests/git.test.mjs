import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { randomUUID } from 'node:crypto';
import { createServerGateway } from '../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs';
import { call, readStream } from '../generated/client.mjs';
const exec = promisify(execFile);

test('native VCS status, refs, diff, selected-file commit stream, push, pull and worktrees', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-git-'));
  let gateway;
  t.after(async () => { await gateway?.close(); await rm(directory, { recursive: true, force: true }); });
  const cwd = join(directory, 'repo'), remote = join(directory, 'remote.git');
  await mkdir(cwd);
  const git = (...args) => exec('git', ['-C', cwd, ...args]);
  await git('init', '-b', 'main');
  await git('config', 'user.name', 'Fixture');
  await git('config', 'user.email', 'fixture@example.test');
  await writeFile(join(cwd, 'tracked.txt'), 'before\n');
  await git('add', '.'); await git('commit', '-m', 'initial');
  await exec('git', ['init', '--bare', remote]);
  await git('remote', 'add', 'origin', remote);
  await git('push', '-u', 'origin', 'main');
  gateway = await createServerGateway({ token: 'ab'.repeat(32), directory: join(directory, 'state'), piConfig: { enabled: false } });
  const { token } = await gateway.official.management.desktopSession();
  const ws = async () => {
    const response = await fetch(gateway.serverURL + '/api/auth/websocket-ticket', { method: 'POST',
      headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' }, body: '{}' });
    assert.equal(response.status, 200);
    return gateway.serverURL.replace('http:', 'ws:') + '/ws?orchestrationProtocol=2&wsTicket=' + (await response.json()).ticket;
  };
  const rpc = async (method, input) => call(await ws(), method, input);
  assert.equal((await rpc('vcs.refreshStatus', { cwd })).refName, 'main');
  assert((await rpc('vcs.listRefs', { cwd, limit: 200, refKind: 'local' })).refs.some(ref => ref.name === 'main'));
  await rpc('vcs.createRef', { cwd, refName: 'feature/test', switchRef: true });
  assert.equal((await rpc('vcs.refreshStatus', { cwd })).refName, 'feature/test');
  await writeFile(join(cwd, 'tracked.txt'), 'after\n');
  await writeFile(join(cwd, 'keep.txt'), 'do not commit\n');
  await git('add', 'keep.txt'); // Existing unrelated staged work must not enter the commit.
  const status = await rpc('vcs.refreshStatus', { cwd });
  assert(status.workingTree.files.some(file => file.path === 'tracked.txt'));
  await assert.rejects(rpc('review.getDiffPreview', { cwd }), error => error._tag === 'VcsRepositoryDetectionError');
  await rpc('projects.mutate', { type: 'project.create', commandId: randomUUID(), projectId: randomUUID(),
    title: 'Git fixture', workspaceRoot: cwd });
  const outside = join(directory, 'outside');
  await mkdir(outside);
  await symlink(outside, join(cwd, 'escape'));
  await assert.rejects(rpc('review.getDiffPreview', { cwd: join(cwd, 'escape') }),
    error => error._tag === 'VcsRepositoryDetectionError');
  const preview = await rpc('review.getDiffPreview', { cwd });
  assert(preview.sources.some(source => source.diff.includes('+after')));
  const events = await readStream(await ws(), 'git.runStackedAction', {
    cwd, actionId: randomUUID(), action: 'commit', commitMessage: 'selected fixture', filePaths: ['tracked.txt'],
  }, { filter: event => event.kind === 'action_finished' || event.kind === 'action_failed' });
  assert.equal(events[0].kind, 'action_finished', JSON.stringify(events[0]));
  assert.equal(events[0].result.commit.status, 'created');
  const committed = (await git('show', '--pretty=', '--name-only', 'HEAD')).stdout.trim();
  assert.equal(committed, 'tracked.txt');
  assert((await git('status', '--porcelain')).stdout.includes('keep.txt'));
  const pushed = await readStream(await ws(), 'git.runStackedAction', { cwd, actionId: randomUUID(), action: 'push' },
    { filter: event => event.kind === 'action_finished' || event.kind === 'action_failed' });
  assert.equal(pushed[0].kind, 'action_finished', JSON.stringify(pushed[0]));
  assert.equal((await rpc('vcs.pull', { cwd })).status, 'skipped_up_to_date');
  await rpc('vcs.switchRef', { cwd, refName: 'main' });
  const path = join(directory, 'worktree');
  const tree = await rpc('vcs.createWorktree', { cwd, refName: 'main', newRefName: 'feature/tree', path });
  assert.equal(tree.worktree.path, path);
  assert.equal((await rpc('vcs.refreshStatus', { cwd: path })).refName, 'feature/tree');
  await rpc('vcs.removeWorktree', { cwd, path });
});
