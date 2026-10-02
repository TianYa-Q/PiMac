import { test } from 'node:test';
import assert from 'node:assert/strict';
import { projectPiToolActivityData, MAX_TOOL_OUTPUT_CHARS } from '../pi-tool-activity.mjs';

test('Pi projection preserves input, multiline output and nested calls', () => {
  const data = { toolName: 'codemode', input: { code: 'const n = 1;\ntext(n);' },
    rawOutput: { content: 'Script completed\nOutput:\n1' }, nestedCalls: { complete: true, calls: [] } };
  const projected = projectPiToolActivityData(data);
  assert.deepEqual(projected.input, data.input);
  assert.deepEqual(projected.rawOutput, data.rawOutput);
  assert.deepEqual(projected.nestedCalls, data.nestedCalls);
  assert.deepEqual(projectPiToolActivityData({ input: { path: 'file.swift', offset: 10, limit: 20 } }).input,
    { path: 'file.swift', offset: 10, limit: 20 });
});

test('large display output is explicitly bounded; empty output remains empty', () => {
  const output = projectPiToolActivityData({ rawOutput: { content: 'x'.repeat(MAX_TOOL_OUTPUT_CHARS + 1) } }).rawOutput.content;
  assert(output.startsWith('x'.repeat(MAX_TOOL_OUTPUT_CHARS)));
  assert(output.endsWith('[显示内容已截断：超过 200,000 字符]'));
  assert.equal(projectPiToolActivityData({ rawOutput: { content: '' } }).rawOutput.content, '');
});
