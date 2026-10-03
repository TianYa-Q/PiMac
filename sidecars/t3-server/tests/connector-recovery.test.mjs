import test from 'node:test';
import assert from 'node:assert/strict';
import { createConnectorRecovery } from '../connector-recovery.mjs';

test('only sustained total outage resets a connector; one live edge prevents reset', () => {
  const recovery = createConnectorRecovery();
  assert.equal(recovery.observe(1, false, 0), false);
  assert.equal(recovery.observe(1, false, 29_999), false);
  assert.equal(recovery.observe(1, false, 30_000), true);
  assert.equal(recovery.observe(1, false, 30_001), false);
  for (let n = 0; n < 20; n++) assert.equal(recovery.observe(2, true, 40_000 + n * 10_000), false);
});

test('PID replacement does not bypass cooldown or finite budget; stable health replenishes it', () => {
  const recovery = createConnectorRecovery();
  recovery.observe(1, false, 0);
  assert.equal(recovery.observe(1, false, 30_000), true);
  recovery.observe(2, false, 31_000);
  assert.equal(recovery.observe(2, false, 80_000), false);
  assert.equal(recovery.observe(2, false, 150_000), true);
  recovery.observe(3, false, 151_000);
  assert.equal(recovery.observe(3, false, 300_000), false);
  assert.equal(recovery.observe(4, false, 400_000), false);
  recovery.observe(4, true, 410_000);
  recovery.observe(4, true, 470_000);
  recovery.observe(4, false, 480_000);
  assert.equal(recovery.observe(4, false, 510_000), true);
});

test('brief recovery starts a fresh outage window without replenishing reset budget', () => {
  const recovery = createConnectorRecovery();
  recovery.observe(1, false, 0);
  recovery.observe(1, true, 29_000);
  assert.equal(recovery.observe(1, false, 31_000), false);
  assert.equal(recovery.observe(1, false, 60_999), false);
  assert.equal(recovery.observe(1, false, 61_000), true);
});
