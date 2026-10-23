import { constants } from 'node:fs';
import { mkdtemp, open, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

export const MAX_SESSION_HTML_BYTES = 32 * 1024 * 1024;

/** 只让 Pi 写入宿主生成的私有临时目录；不接受客户端路径，也不读取 RPC 返回的任意路径。 */
export async function exportPiSessionHtml(
  request: (command: { type: 'export_html'; outputPath: string }) => Promise<unknown>,
  systemPrompt: string,
): Promise<string> {
  const directory = await mkdtemp(join(tmpdir(), 'pimac-session-export-'));
  const outputPath = join(directory, 'session.html');
  try {
    const result = await request({ type: 'export_html', outputPath });
    if (!result || typeof result !== 'object' || !('path' in result) || result.path !== outputPath) {
      throw new Error('Pi returned an invalid HTML export path');
    }
    const file = await open(outputPath, constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const info = await file.stat();
      if (!info.isFile() || info.size === 0 || info.size > MAX_SESSION_HTML_BYTES) {
        throw new Error('Pi HTML export is empty or exceeds 32 MiB');
      }
      const html = await file.readFile('utf8');
      if (Buffer.byteLength(html, 'utf8') > MAX_SESSION_HTML_BYTES) {
        throw new Error('Pi HTML export exceeds 32 MiB');
      }
      // Pi 1.3 的 exporter 读取 agent.state.systemPrompt，恢复后该旧字段可能为空。
      // 仅补齐原生模板的数据块，保留原生样式、分支、工具渲染和全部会话数据。
      const marker = /(<script id="session-data" type="application\/json">)([A-Za-z0-9+/=]+)(<\/script>)/;
      const match = marker.exec(html);
      if (!match) throw new Error('Unsupported Pi HTML export template');
      const data: unknown = JSON.parse(Buffer.from(match[2]!, 'base64').toString('utf8'));
      if (!data || typeof data !== 'object' || !('entries' in data) || !Array.isArray(data.entries)) {
        throw new Error('Invalid Pi HTML session data');
      }
      const encoded = Buffer.from(JSON.stringify({ ...data, systemPrompt })).toString('base64');
      const result = html.replace(marker, (_match, start: string, _data: string, end: string) => start + encoded + end);
      if (Buffer.byteLength(result, 'utf8') > MAX_SESSION_HTML_BYTES) throw new Error('Pi HTML export exceeds 32 MiB');
      return result;
    } finally {
      await file.close();
    }
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
}
