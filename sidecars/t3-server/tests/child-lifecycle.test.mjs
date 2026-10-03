import assert from 'node:assert/strict';
import test from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { acquireChildLease } from '../../../Sources/PiMacApp/Resources/t3-bridge/child-lease.mjs';

const leaseURL = new URL('../../../Sources/PiMacApp/Resources/t3-bridge/child-lease.mjs', import.meta.url).href;
const gateway = fileURLToPath(new URL('../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs', import.meta.url));
const fixture = fileURLToPath(new URL('./fixtures/pi.mjs', import.meta.url));
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
function directory(t) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pimac-lifecycle-'));
  fs.chmodSync(dir, 0o700);
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  return dir;
}
async function waitFor(check) {
  for (let n = 0; n < 200; n++) { if (check()) return; await delay(50); }
  throw new Error('Lifecycle condition timed out');
}

test('kernel lease rejects a second writer and is reusable without deleting its inode', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pimac-lease-'));
  try {
    const auth = path.join(dir, 'auth.json');
    const release = acquireChildLease(auth);
    const inode = fs.statSync(path.join(dir, 'child-owner.lock')).ino;
    assert.throws(() => acquireChildLease(auth), /already owned/);
    release(); release();
    const again = acquireChildLease(auth);
    assert.equal(fs.statSync(path.join(dir, 'child-owner.lock')).ino, inode);
    again();
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('rapid relaunch waits for the previous kernel owner instead of failing or stealing', { timeout: 10000 }, async t => {
  const dir = directory(t), auth = path.join(dir, 'auth.json');
  const release = acquireChildLease(auth);
  const waiter = spawn(process.execPath, ['--input-type=module', '-e',
    `import {acquireChildLease} from ${JSON.stringify(leaseURL)}; const release=acquireChildLease(${JSON.stringify(auth)}, {waitSeconds:2}); release();`],
  { stdio: 'ignore' });
  t.after(() => { release(); waiter.kill('SIGKILL'); });
  const exited = once(waiter, 'exit');
  await delay(200);
  assert.equal(waiter.exitCode, null);
  release();
  const [code] = await exited; assert.equal(code, 0);
});

test('SIGKILL releases kernel lease; dead diagnostic marker is archived on restart', { timeout: 15000 }, async t => {
  const dir = directory(t), auth = path.join(dir, 'auth.json');
  const child = spawn(process.execPath, ['--input-type=module', '-e',
    `import {acquireChildLease} from ${JSON.stringify(leaseURL)}; acquireChildLease(${JSON.stringify(auth)}); setInterval(()=>{},1000);`],
  { stdio: 'ignore' });
  t.after(() => child.kill('SIGKILL'));
  await waitFor(() => fs.existsSync(path.join(dir, 'child-owner.json')));
  assert.throws(() => acquireChildLease(auth), /already owned/);
  const exited = once(child, 'exit'); child.kill('SIGKILL'); await exited;
  const release = acquireChildLease(auth);
  assert.ok(fs.readdirSync(dir).some(name => name.startsWith('child-owner.json.stale-')));
  release();
});

test('kernel-backed diagnostic PID reuse never blocks startup', t => {
  const dir = directory(t), auth = path.join(dir, 'auth.json');
  fs.writeFileSync(path.join(dir, 'child-owner.json'), JSON.stringify({ pid: process.pid, leaseVersion: 2 }), { mode: 0o600 });
  const release = acquireChildLease(auth); release();
});

test('legacy live PID and symlink locks remain denied', t => {
  const dir = directory(t), auth = path.join(dir, 'auth.json');
  const marker = path.join(dir, 'child-owner.json');
  fs.writeFileSync(marker, JSON.stringify({ pid: process.pid }), { mode: 0o600 });
  assert.throws(() => acquireChildLease(auth), /still alive/);
  fs.unlinkSync(marker);
  fs.unlinkSync(path.join(dir, 'child-owner.lock'));
  const target = path.join(dir, 'unrelated'); fs.writeFileSync(target, 'unchanged');
  fs.symlinkSync(target, path.join(dir, 'child-owner.lock'));
  assert.throws(() => acquireChildLease(auth));
  assert.equal(fs.readFileSync(target, 'utf8'), 'unchanged');
});

function launch(dir) {
  const binary = path.join(dir, 'fixture-pi');
  fs.writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${fixture}" "$@"\n`, { mode: 0o700 });
  const child = spawn(process.execPath, [gateway], { env: { ...process.env,
    PIMAC_T3_BRIDGE_TOKEN: 'ab'.repeat(32), PIMAC_T3_AUTH_FILE: path.join(dir, 'auth.json'), PIMAC_PI_BINARY: binary },
  stdio: ['pipe', 'pipe', 'ignore'] });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  return { child, ready: () => output.split('\n').filter(Boolean).map(line => JSON.parse(line)).find(r => r.type === 'ready') };
}

test('real Server follows stdin EOF and can repeatedly restart in the same state', { timeout: 60000 }, async t => {
  const dir = directory(t);
  let previousPort;
  for (let n = 0; n < 3; n++) {
    const { child, ready } = launch(dir);
    t.after(() => { if (child.exitCode === null) child.kill('SIGKILL'); });
    await waitFor(ready);
    const port = ready().serverPort;
    if (previousPort !== undefined) assert.equal(port, previousPort, 'restart must preserve the Tunnel origin');
    previousPort = port;
    assert.equal((await fetch(`http://127.0.0.1:${port}/.well-known/t3/environment`)).status, 200);
    const exited = once(child, 'exit'); child.stdin.end();
    const [code] = await exited;
    assert.equal(code, 0);
    assert.equal(fs.existsSync(path.join(dir, 'child-owner.json')), false);
    await assert.rejects(fetch(`http://127.0.0.1:${port}/.well-known/t3/environment`));
  }
});

test('Server exits when its Mac-like parent crashes, even with an inherited stdin writer', { timeout: 30000 }, async t => {
  const dir = directory(t);
  const binary = path.join(dir, 'fixture-pi');
  fs.writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${fixture}" "$@"\n`, { mode: 0o700 });
  const env = { ...process.env, PIMAC_T3_BRIDGE_TOKEN: 'ab'.repeat(32),
    PIMAC_T3_AUTH_FILE: path.join(dir, 'auth.json'), PIMAC_PI_BINARY: binary };
  // stdin is inherited from the test's still-open pipe, so EOF cannot help.
  const launcher = spawn(process.execPath, ['--input-type=module', '-e',
    `import {spawn} from 'node:child_process'; spawn(${JSON.stringify(process.execPath)}, [${JSON.stringify(gateway)}], {stdio: ['inherit','inherit','ignore']}); setInterval(()=>{},1000);`],
  { env, stdio: ['pipe', 'pipe', 'ignore'] });
  let output = '';
  launcher.stdout.on('data', chunk => { output += chunk; });
  t.after(() => launcher.kill('SIGKILL'));
  await waitFor(() => output.includes('"type":"ready"'));
  const serverPID = JSON.parse(fs.readFileSync(path.join(dir, 'child-owner.json'), 'utf8')).pid;
  t.after(() => { try { process.kill(serverPID, 'SIGKILL'); } catch {} });
  const exited = once(launcher, 'exit'); launcher.kill('SIGKILL'); await exited;
  await waitFor(() => !fs.existsSync(path.join(dir, 'child-owner.json')));
  const release = acquireChildLease(path.join(dir, 'auth.json')); release();
  launcher.stdin.destroy(); launcher.stdout.destroy();
});

test('EOF during Server startup cancels startup and releases ownership', { timeout: 15000 }, async t => {
  const dir = directory(t);
  const { child } = launch(dir);
  t.after(() => { if (child.exitCode === null) child.kill('SIGKILL'); });
  const exited = once(child, 'exit'); child.stdin.end(); await exited;
  assert.equal(fs.existsSync(path.join(dir, 'child-owner.json')), false);
  const release = acquireChildLease(path.join(dir, 'auth.json')); release();
});
