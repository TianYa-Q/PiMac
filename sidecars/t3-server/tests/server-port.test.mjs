import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import net from 'node:net';
import { prepareServerPort } from '../server-port.mjs';

function directory(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pimac-port-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}
const listen = port => new Promise((resolve, reject) => {
  const socket = net.createServer(); socket.once('error', reject);
  socket.listen(port, '127.0.0.1', () => resolve(socket));
});
const close = socket => new Promise(resolve => socket.close(resolve));

test('port is private, saved only after listening, and reused across restarts', async t => {
  const dir = directory(t), file = path.join(dir, 'loopback-port.json');
  const first = await prepareServerPort(dir);
  assert.equal(fs.existsSync(file), false);
  assert.throws(() => first.commit(first.port + 1), /Unexpected/);
  const server = await listen(first.port);
  first.commit(server.address().port);
  assert.equal(fs.statSync(file).mode & 0o777, 0o600);
  await close(server);
  for (let n = 0; n < 3; n++) {
    const next = await prepareServerPort(dir);
    assert.equal(next.port, first.port);
    next.commit(next.port);
  }
});

test('occupied port selects a new origin without touching owner or persisted state before bind', async t => {
  const dir = directory(t), events = [];
  const first = await prepareServerPort(dir); first.commit(first.port);
  const owner = await listen(first.port);
  t.after(() => close(owner));
  const next = await prepareServerPort(dir, { record: (event, fields) => events.push({ event, ...fields }) });
  assert.notEqual(next.port, first.port);
  assert.equal(JSON.parse(fs.readFileSync(path.join(dir, 'loopback-port.json'))).port, first.port);
  assert(events.some(e => e.reason === 'occupied-reassigned'));
  assert.equal(owner.listening, true);
  const server = await listen(next.port); next.commit(server.address().port); await close(server);
  assert.equal((await prepareServerPort(dir)).port, next.port);
});

test('unsafe or malformed saved ports fail closed, without altering files', async t => {
  const dir = directory(t), file = path.join(dir, 'loopback-port.json');
  for (const contents of ['not json', '{"version":2,"port":12345}', '{"version":1,"port":0}',
    '{"version":1,"port":"12345"}', '{"version":1,"port":65536}']) {
    fs.writeFileSync(file, contents, { mode: 0o600 });
    await assert.rejects(prepareServerPort(dir));
    assert.equal(fs.readFileSync(file, 'utf8'), contents);
  }
  fs.writeFileSync(file, '{"version":1,"port":12345}'); fs.chmodSync(file, 0o644);
  await assert.rejects(prepareServerPort(dir), /Unsafe/);
  fs.unlinkSync(file);
  const target = path.join(dir, 'target'); fs.writeFileSync(target, 'untouched');
  fs.symlinkSync(target, file);
  await assert.rejects(prepareServerPort(dir));
  assert.equal(fs.readFileSync(target, 'utf8'), 'untouched');
});
