import { test } from 'node:test';
import assert from 'node:assert/strict';
import { httpAllowed, rpcAllowed } from '../native.mjs';

test('mobile dispatch and projection refresh are allowed narrowly', () => {
  assert.equal(rpcAllowed('orchestration.dispatchCommand'), true);
  assert.equal(rpcAllowed('orchestration.getThreadProjection'), true);
  assert.equal(rpcAllowed('orchestration.getUnknownProjection'), false);
});

test('mobile thread launch is allowed without opening the orchestration namespace', () => {
  assert.equal(rpcAllowed('orchestration.launchThread'), true);
  assert.equal(rpcAllowed('orchestration.unknown'), false);
  assert.equal(rpcAllowed('orchestration.launchThreads'), false);
});

test('official scheduled-task RPCs are allowed without opening the namespace or HTTP routes', () => {
  for (const action of ['list', 'subscribe', 'upsert', 'setEnabled', 'delete', 'runNow']) {
    assert.equal(rpcAllowed(`scheduledTasks.${action}`), true);
  }
  for (const method of ['scheduledTasks', 'scheduledTasks.unknown', 'scheduledTasks.deleteAll']) {
    assert.equal(rpcAllowed(method), false);
  }
  for (const method of ['GET', 'POST', 'PUT', 'DELETE']) {
    assert.equal(httpAllowed(method, '/api/scheduledTasks'), false);
  }
});

test('Git and diff RPCs are explicit, without shell or administration access', () => {
  for (const method of ['subscribeVcsStatus', 'subscribeWorktreeSetup', 'worktreeSetup.cancel',
    'vcs.refreshStatus', 'vcs.listRefs', 'vcs.pull', 'vcs.createRef', 'vcs.switchRef', 'vcs.init',
    'vcs.createWorktree', 'vcs.removeWorktree', 'git.runStackedAction', 'git.resolvePullRequest',
    'git.preparePullRequestThread', 'review.getDiffPreview', 'review.getDiffFileContents']) {
    assert.equal(rpcAllowed(method), true, method);
  }
  for (const method of ['vcs.unknown', 'git.unknown', 'review.open', 'terminal.open', 'shell.openInEditor']) {
    assert.equal(rpcAllowed(method), false, method);
  }
  assert.equal(httpAllowed('POST', '/api/git'), false);
});

test('mobile Usage / Limits RPCs are allowed without opening server administration', () => {
  for (const method of ['server.refreshProviders', 'server.getUsageSummary', 'server.refreshUsageRates']) {
    assert.equal(rpcAllowed(method), true);
  }
  for (const method of ['server.updateProvider', 'server.updateSettings', 'server.unknown', 'provider.consumeResetCredit']) {
    assert.equal(rpcAllowed(method), false);
  }
  assert.equal(httpAllowed('POST', '/api/usage'), false);
});

test('mobile attachment RPCs and signed POST uploads are allowed narrowly', () => {
  for (const method of ['attachments.createUploadUrl', 'attachments.delete', 'assets.persistChatAttachments', 'assets.createUrl']) {
    assert.equal(rpcAllowed(method), true);
  }
  assert.equal(rpcAllowed('attachments.unknown'), false);
  assert.equal(httpAllowed('POST', '/api/attachments/upload/signed-token'), true);
  assert.equal(httpAllowed('POST', '/api/attachments/upload/signed-token?ignored=1'), true);
  for (const method of ['GET', 'PUT', 'DELETE', 'OPTIONS']) {
    assert.equal(httpAllowed(method, '/api/attachments/upload/signed-token'), false);
  }
  for (const path of ['/api/attachments/upload', '/api/attachments/upload/', '/api/attachments/upload/token/extra', '/api/attachments/other/token']) {
    assert.equal(httpAllowed('POST', path), false);
  }
});
