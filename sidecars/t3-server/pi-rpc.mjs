// Private provider transport. Never exposed as an API to UI or remote clients.
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { StringDecoder } from 'node:string_decoder';

export class PiRPC {
  constructor({ binaryPath = 'pi', binaryArgs = [], args = [], cwd, env, onEvent = () => {}, onExit = () => {}, timeoutMs = 30000 }) {
    this.pending = new Map(); this.closed = false; this.timeoutMs = timeoutMs;
    this.child = spawn(binaryPath, [...binaryArgs, '--mode', 'rpc', ...args], { cwd, env, stdio: ['pipe', 'pipe', 'pipe'], shell: false });
    const decoder = new StringDecoder('utf8'); let buffer = '';
    this.child.stdout.on('data', chunk => {
      buffer += decoder.write(chunk);
      let end;
      while ((end = buffer.indexOf('\n')) !== -1) {
        const line = buffer.slice(0, end).replace(/\r$/, ''); buffer = buffer.slice(end + 1);
        if (!line) continue;
        try {
          const record = JSON.parse(line);
          if (record.type === 'response' && this.pending.has(record.id)) {
            const pending = this.pending.get(record.id); this.pending.delete(record.id); clearTimeout(pending.timer);
            if (record.success === true) pending.resolve(record.data);
            else pending.reject(new Error('Pi rejected ' + pending.type)); // Do not leak provider bodies/secrets.
          } else onEvent(record);
        } catch { this.fail(new Error('Invalid Pi protocol')); this.child.kill('SIGTERM'); }
      }
      if (Buffer.byteLength(buffer) > 16 * 1024 * 1024) { this.fail(new Error('Pi record capacity exceeded')); this.child.kill('SIGTERM'); }
    });
    // Stderr may contain credentials, prompts or extension diagnostics. Drain only.
    this.child.stderr.resume();
    this.child.stdin.on('error', () => this.fail(new Error('Pi input unavailable')));
    this.child.once('error', () => this.fail(new Error('Pi executable unavailable')));
    this.exited = new Promise(resolve => this.child.once('close', (code, signal) => {
      this.hasExited = true;
      clearTimeout(this.terminateTimer); clearTimeout(this.killTimer);
      this.fail(new Error('Pi process exited')); onExit({ code, signal, expected: this.stopping === true }); resolve();
    }));
    this.writeChain = Promise.resolve();
  }
  fail(error) {
    this.closed = true;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(error); }
    this.pending.clear();
  }
  write(record) {
    // Serial writes wait for the stream callback (including backpressure).
    const operation = this.writeChain.then(() => new Promise((resolve, reject) => {
      if (this.closed || this.stopping) { reject(new Error('Pi transport closed')); return; }
      this.child.stdin.write(JSON.stringify(record) + '\n', error => error ? reject(new Error('Pi write failed')) : resolve());
    }));
    this.writeChain = operation.catch(() => {}); return operation;
  }
  request(command) {
    if (this.closed || this.stopping) return Promise.reject(new Error('Pi transport closed'));
    if (this.pending.size >= 64) return Promise.reject(new Error('Pi request capacity exceeded'));
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        // A mutation timeout has an unknown outcome. Never replay it.
        reject(new Error('Pi response timeout; outcome unknown'));
      }, this.timeoutMs);
      this.pending.set(id, { resolve, reject, timer, type: command.type });
      this.write({ ...command, id }).catch(error => {
        const pending = this.pending.get(id); if (!pending) return;
        this.pending.delete(id); clearTimeout(timer); reject(error);
      });
    });
  }
  async stop() {
    if (!this.stopping) {
      this.stopping = true; this.fail(new Error('Pi transport stopped'));
      if (!this.hasExited) {
        this.child.stdin.end();
        this.terminateTimer = setTimeout(() => this.child.kill('SIGTERM'), 1000);
        this.killTimer = setTimeout(() => this.child.kill('SIGKILL'), 3000);
      }
    }
    await this.exited;
  }
}
