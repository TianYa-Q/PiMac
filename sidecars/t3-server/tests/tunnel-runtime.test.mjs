import test from 'node:test';
import { exerciseTunnelRuntime } from '../generated/tunnel-runtime.mjs';

test('patched official connector supervisor updates health on output, crash, replacement and unlink',
  { timeout: 15000 }, exerciseTunnelRuntime);
