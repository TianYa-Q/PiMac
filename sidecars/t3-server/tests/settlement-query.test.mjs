import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { DatabaseSync } from 'node:sqlite';

test('settlement lookup reads only subtree identities and terminates on lineage cycles', async () => {
  const patches = JSON.parse(await readFile(new URL('../patches.json', import.meta.url), 'utf8'));
  const patch = patches['apps/server/src/orchestration-v2/ProjectionStore.ts']
    .find(patch => patch.newText.includes('WITH RECURSIVE settlement_tree'));
  // 验证构建实际注入的 SQL，而不是另写一份可能与运行时代码漂移的查询。
  const query = patch.newText.match(/WITH RECURSIVE settlement_tree[\s\S]*?SELECT thread_id FROM settlement_tree/)[0]
    .replace('${threadId}', '?');
  const db = new DatabaseSync(':memory:');
  try {
    // 刻意没有运行、消息或工具表：子树发现不应依赖这些昂贵投影。
    db.exec('CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, payload_json TEXT, deleted_at TEXT)');
    const insert = db.prepare('INSERT INTO orchestration_v2_projection_threads VALUES (?, ?, ?)');
    const add = (id, parent, archivedAt = null, deletedAt = null) => insert.run(id,
      JSON.stringify({ lineage: { parentThreadId: parent }, archivedAt }), deletedAt);
    add('root', 'grandchild');
    add('child', 'root');
    add('grandchild', 'child');
    add('archived', 'root', '2026-01-01');
    add('behind-archive', 'archived');
    add('deleted', 'root', null, '2026-01-01');
    add('behind-deleted', 'deleted');
    for (let index = 0; index < 1000; index++) add('unrelated-' + index, null);
    const ids = id => db.prepare(query).all(id).map(row => row.thread_id).sort();
    assert.deepEqual(ids('root'), ['child', 'grandchild', 'root']);
    assert.deepEqual(ids('unrelated-0'), ['unrelated-0']);
    // 保留目标 ID，由原有命令校验负责准确报告不存在/归档/删除，不能伪装成功。
    assert.deepEqual(ids('missing'), ['missing']);
    assert.deepEqual(ids('archived'), ['archived', 'behind-archive']);
  } finally { db.close(); }
});
