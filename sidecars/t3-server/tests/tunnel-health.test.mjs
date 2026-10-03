import test from 'node:test';
import assert from 'node:assert/strict';
import { createTunnelHealth } from '../tunnel-health.mjs';

function fixture() {
  const events = [];
  return { events, health: createTunnelHealth({ record: (event, fields) => events.push({ event, ...fields }) }) };
}
test('process startup is not edge readiness; config reapply cannot regress connected state', () => {
  const { health, events } = fixture();
  assert.equal(health.status, 'disabled');
  health.start(1); health.config({ status: 'running' });
  assert.equal(health.status, 'connecting');
  health.output(1, 'INF Registered tunnel connection connIndex=0 token=secret');
  assert.equal(health.status, 'connected');
  health.config({ status: 'running' });
  assert.equal(health.status, 'connected');
  health.output(1, 'INF Registered tunnel connection connIndex=1');
  health.output(1, 'ERR Connection terminated connIndex=0');
  assert.equal(health.status, 'connected');
  health.output(1, 'ERR Connection terminated connIndex=1');
  assert.equal(health.status, 'reconnecting');
  health.output(1, 'INF Registered tunnel connection connIndex=0');
  assert.equal(health.status, 'connected');
  assert(!JSON.stringify(events).includes('secret'));
});
test('crash, replacement and intentional stop ignore old connector output', () => {
  const { health } = fixture();
  health.start(1); health.output(1, 'Registered tunnel connection connIndex=0');
  health.exit(1); assert.equal(health.status, 'reconnecting');
  health.output(1, 'Registered tunnel connection connIndex=0');
  assert.equal(health.status, 'reconnecting');
  health.start(2);
  health.output(1, 'Registered tunnel connection connIndex=0');
  health.exit(1); health.stop(1);
  assert.equal(health.status, 'connecting');
  health.output(2, 'Registered tunnel connection connIndex=0');
  health.stop(2); assert.equal(health.status, 'disabled');
  health.output(2, 'Registered tunnel connection connIndex=0');
  assert.equal(health.status, 'disabled');
});
test('errors are finite classifications, not credentials; failures and unlink clear readiness', () => {
  const { health, events } = fixture();
  health.start(1);
  health.output(1, 'ERR Register tunnel error from server side token=secret error="Failed to get tunnel"');
  assert.equal(health.status, 'reconnecting');
  health.output(1, 'ERR private-path secret');
  health.config({ status: 'failed', failure: 'spawn-failed' });
  assert.equal(health.status, 'failed:spawn-failed');
  health.output(1, 'Registered tunnel connection');
  assert.equal(health.status, 'failed:spawn-failed');
  health.config({ status: 'disabled' }); assert.equal(health.status, 'disabled');
  assert(!JSON.stringify(events).includes('secret'));
  assert(!JSON.stringify(events).includes('private-path'));
});
