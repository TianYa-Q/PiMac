import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import { build } from 'esbuild';
import { plugin } from '../build.mjs';

// 走正式打包 plugin，验证 alias 与三份官方 npm 补丁真正进入 bundle，
// 而不是只验证清单/补丁字符串存在。不会启动 Provider 或访问真实凭据。
test('release math tokenizer and dependency patches survive the actual Server bundler', async t => {
  const root = new URL('../../../tmp/', import.meta.url);
  await mkdir(root, { recursive: true });
  const directory = await mkdtemp(new URL('t3-release-math-', root).pathname);
  t.after(() => execFileSync('trash', [directory]));
  const output = directory + '/math.mjs';
  await build({
    entryPoints: [new URL('../upstream/packages/shared/src/markdownMath.ts', import.meta.url).pathname],
    outfile: output, bundle: true, platform: 'node', target: 'node24', format: 'esm', plugins: [plugin],
  });
  const { markdownMathRanges, parseMarkdownWithMath } = await import(output);
  const source = 'Inline $x^2$ and \\(y_1\\), display $$a+b$$ and \\[c\\].';
  assert.deepEqual(markdownMathRanges(source).map(({ tex, display }) => [tex, display]),
    [['x^2', false], ['y_1', false], ['a+b', true], ['c', true]]);
  assert.deepEqual(markdownMathRanges('It costs $5 and $10. Run $HOME then $deploy.'), []);
  const nodes = parseMarkdownWithMath('Display $$x$$.').children[0].children;
  const display = nodes.find(node => node.type === 'inlineMath');
  assert(display?.data.hProperties.className.includes('math-display'));
  const table = '| Formula |\n| --- |\n| $a|b$ |';
  const ranges = markdownMathRanges(table);
  assert.equal(ranges.length, 1);
  assert.equal(ranges[0].tex, 'a|b');
  assert.equal(ranges[0].inTable, true);
});
