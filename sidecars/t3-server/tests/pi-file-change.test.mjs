import test from 'node:test';
import assert from 'node:assert/strict';
import { piFileChangeDetails } from '../pi-file-change.mjs';

test('preserves authoritative Pi diff over proposed input', () => {
  assert.deepEqual(piFileChangeDetails('edit', { oldText: 'old', newText: 'new' }, { details: { diff: '-actual\n+actual' } }), { diffStr: '-actual\n+actual' });
});
test('renders single and batched replacements while running', () => {
  const args = { path: 'a.swift', edits: [{ oldText: 'old\nline', newText: 'new\nline' }, { oldText: 'two', newText: 'three' }] };
  const { diffStr } = piFileChangeDetails('edit', args);
  for (const text of ['a.swift', '-old', '+new', '-two', '+three']) assert(diffStr.includes(text));
  assert(piFileChangeDetails('edit', { path: 'a', oldText: 'before', newText: '' }).diffStr.includes('-before'));
});
test('preserves written content and tolerates missing arguments', () => {
  assert.deepEqual(piFileChangeDetails('write', { content: 'new file' }), { newStr: 'new file' });
  assert.deepEqual(piFileChangeDetails('edit', undefined), {});
});
