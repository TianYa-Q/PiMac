// Protocol-only fixture: never calls a model, shell or real Pi.
// MCP acceptance probes only the test-owned local Server.
import fs from 'node:fs';
import path from 'node:path';
import { StringDecoder } from 'node:string_decoder';
const args = process.argv.slice(2);
if (args.includes('--version')) { console.log('1.0.0'); process.exit(0); }
const option = name => args[args.indexOf(name) + 1];
let sessionId = args.includes('--session-id') ? option('--session-id') : 'fixture-session';
let sessionFile = args.includes('--session') ? option('--session') : '/tmp/pimac-fixture-session.jsonl';
const directory = args.includes('--session-dir') ? option('--session-dir') : undefined;
if (directory) fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
// 模拟 Pi 原生 --fork 的独立会话文件，让父子生命周期测试走真实适配器链路。
if (args.includes('--fork')) {
  sessionId = 'fixture-fork-' + process.pid;
  sessionFile = path.join(process.cwd(), sessionId + '.jsonl');
  fs.writeFileSync(sessionFile, JSON.stringify({ type: 'session', version: 3, id: sessionId,
    timestamp: new Date().toISOString(), cwd: process.cwd() }) + '\n', { mode: 0o600 });
}
const file = directory && path.join(directory, sessionId + '.jsonl');
let model = { provider: 'test', id: 'model', name: 'Test Model', reasoning: true,
  thinkingLevelMap: { xhigh: 'xhigh', max: 'max' }, contextWindow: 10000 }, running = false, completion;
let thinkingLevel = 'off', pendingDialog = false;
const send = value => process.stdout.write(JSON.stringify(value) + '\r\n');
const decoder = new StringDecoder('utf8'); let buffer = '';
process.stdin.on('data', chunk => {
  buffer += decoder.write(chunk); let end;
  while ((end = buffer.indexOf('\n')) !== -1) {
    const command = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
    fs.appendFileSync(file ?? path.join(process.cwd(), 'fixture-rpc.ndjson'), JSON.stringify({ command: command.type, message: command.message, streamingBehavior: command.streamingBehavior, sessionId,
      imageCount: command.images?.length ?? 0, secretInherited: !!process.env.PIMAC_T3_BRIDGE_TOKEN }) + '\n', { mode: 0o600 });
    const response = data => send({ id: command.id, type: 'response', command: command.type, success: true, ...(data ? { data } : {}) });
    switch (command.type) {
      case 'get_state': response({ sessionId, sessionFile, isStreaming: running, isCompacting: false, model, thinkingLevel }); break;
      case 'get_entries': response({ entries: [] }); break;
      case 'get_messages': response({ messages: [] }); break;
      case 'new_session': sessionId = 'fixture-' + process.pid; sessionFile = path.join(process.cwd(), sessionId + '.jsonl');
        fs.writeFileSync(sessionFile, JSON.stringify({ type: 'session', version: 3, id: sessionId, timestamp: new Date().toISOString(), cwd: process.cwd() }) + '\n', { mode: 0o600 });
        response({ cancelled: false }); break;
      case 'switch_session': sessionFile = command.sessionPath; response({ cancelled: false }); break;
      case 'get_session_stats': response({ tokens: { input: 100, output: 20, cacheRead: 80, cacheWrite: 0, total: 200 },
        cost: 0.012, contextUsage: { tokens: 200, contextWindow: 10000, percent: 2 } }); break;
      case 'compact': {
        const result = { summary: 'Fixture summary', tokensBefore: 200, estimatedTokensAfter: 100 };
        send({ type: 'compaction_start' }); send({ type: 'compaction_end', result }); response(result); break;
      }
      case 'get_commands': response({ commands: [{ name: 'pimac-fast', source: 'extension' }, { name: 'accounts', source: 'extension' }] }); break;
      case 'get_available_models': response({ models: [model, ...(process.env.PIMAC_FIXTURE_EXTRA_MODEL === '1'
        ? [{ ...model, id: 'alternate', name: 'Alternate Model' }] : [])] }); break;
      case 'set_model': model = { provider: command.provider, id: command.modelId, name: command.modelId, api: command.provider === 'openai' ? 'openai-responses' : command.provider === 'openai-codex' ? 'openai-codex-responses' : 'test' }; response(model); break;
      case 'set_thinking_level': thinkingLevel = command.level; response(); break;
      case 'set_session_name': case 'clear_queue': response(); break;
      case 'extension_ui_response':
        if (pendingDialog) {
          pendingDialog = false; running = false;
          send({ type: 'message_start', message: { role: 'assistant', content: [] } });
          send({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: 'Dialog: ' + (command.value ?? 'cancelled') } });
          send({ type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: 'Dialog: ' + (command.value ?? 'cancelled') }], stopReason: 'stop' } });
          send({ type: 'agent_settled' });
        }
        break;
      case 'abort':
        clearTimeout(completion); running = false; send({ type: 'agent_settled' }); response(); break;
      case 'prompt': {
        if (command.message.startsWith('/pimac-fast ')) {
          send({ type: 'extension_ui_request', method: 'setStatus', statusKey: 'pimac-fast', statusText: command.message.split(' ')[1] });
          response({ disposition: 'handled' }); break;
        }
        if (command.message.startsWith('/accounts switch ')) {
          send({ type: 'extension_ui_request', method: 'setStatus', statusKey: 'account-usage-gui', statusText: JSON.stringify({ version: 2, provider: model.provider, activeAccount: command.message.split(' ')[2], updatedAt: Date.now(), accounts: [] }) });
          response({ disposition: 'handled' }); break;
        }
        if (running && command.streamingBehavior === 'steer') {
          response({ disposition: 'queued' });
          break;
        }
        if (command.message === 'exit') { process.exit(3); }
        if (command.message === 'no-response') break;
        response({ disposition: command.message === '/handled' ? 'handled' : 'started' });
        if (command.message === '/handled') break;
        running = true; send({ type: 'agent_start' });
        if (command.message.startsWith('account-selection-')) {
          send({ type: 'extension_ui_request', method: 'setStatus', statusKey: 'account-usage-gui',
            statusText: JSON.stringify({ version: 2, provider: 'openai', activeAccount: command.message.slice('account-selection-'.length),
              updatedAt: Date.now(), accounts: [], supportsAccountSwitch: true, managesSelectedAuth: true }) });
        }
        if (command.message === 'wait') break;
        if (['mcp-discovery', 'html-render', 'mcp-model-targets'].includes(command.message)) {
          send({ type: 'message_start', message: { role: 'assistant', content: [] } });
          // 使用上游注入的会话凭据，只输出工具名；不把 token 写入日志或投影。
          void (async () => {
            const headers = { authorization: 'Bearer ' + process.env.T3_MCP_BEARER_TOKEN,
              'content-type': 'application/json', accept: 'application/json, text/event-stream',
              'mcp-protocol-version': '2025-06-18' };
            const request = async (id, method, params) => {
              const response = await fetch(process.env.T3_MCP_URL, { method: 'POST', headers,
                body: JSON.stringify({ jsonrpc: '2.0', id, method, params }) });
              const session = response.headers.get('mcp-session-id');
              if (session) headers['mcp-session-id'] = session;
              const body = await response.text();
              if (!response.ok) throw new Error('MCP status ' + response.status);
              const payload = response.headers.get('content-type')?.includes('text/event-stream')
                ? body.split('\n').find(line => line.startsWith('data:')).slice(5).trim() : body;
              const parsed = JSON.parse(payload);
              if (parsed.error) throw new Error(parsed.error.message);
              return parsed.result;
            };
            await request(1, 'initialize', { protocolVersion: '2025-06-18', capabilities: {},
              clientInfo: { name: 'pimac-fixture', version: '1' } });
            if (command.message === 'mcp-model-targets') {
              const capabilities = await request(2, 'tools/call', { name: 'orchestrator_capabilities', arguments: {} });
              const accepted = [];
              // 省略 target 仍继承父设置；模型覆盖和完整 target 都交给官方解析器处理。
              for (const [index, target] of [undefined, { model: 'test/alternate' },
                { providerInstanceId: 'pi', model: 'test/alternate', driverKind: 'pi' }].entries()) {
                accepted.push(await request(3 + index, 'tools/call', { name: 'delegate_task', arguments: {
                  task: 'catalog-selected child', ...(target ? { target } : {}), mode: 'async' } }));
              }
              const text = JSON.stringify({ modelTargets: true, capabilities, accepted });
              send({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: text } });
              send({ type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text }], stopReason: 'stop' } });
              return;
            }
            if (command.message === 'html-render') {
              const html = '<!doctype html><html><head><style>h2{font-size:20px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:12px}.box{background:var(--secondary);padding:20px;border-radius:8px}p{color:var(--muted-foreground)}</style></head><body><h2>侧栏前后对比</h2><div class="grid"><div class="box">修改前<p>标题、项目、时间各占一行</p></div><div class="box">修改后<p>紧凑标题与单行元信息</p></div></div></body></html>';
              send({ type: 'tool_execution_start', toolCallId: 'html-1', toolName: 'mcp__t3-code__html_render', args: { title: '侧栏前后对比', html, height: 260 } });
              const result = await request(2, 'tools/call', { name: 'html_render', arguments: { title: '侧栏前后对比', html, height: 260 } });
              if (result.isError) throw new Error(JSON.stringify(result.content));
              send({ type: 'tool_execution_end', toolCallId: 'html-1', toolName: 'mcp__t3-code__html_render', result, isError: false });
              send({ type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text: '已完成页面展示。' }], stopReason: 'stop' } });
              return;
            }
            const tools = await request(2, 'tools/list', {});
            const names = tools.tools.map(tool => tool.name);
            const task = await request(3, 'tools/call', { name: 'schedule_task', arguments: {
              title: 'MCP acceptance timer', prompt: 'test-owned timer',
              schedule: { type: 'interval', everyMs: 3600000 } } });
            if (task.isError) throw new Error(JSON.stringify(task.content));
            send({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: JSON.stringify(names) } });
            send({ type: 'message_end', message: { role: 'assistant',
              content: [{ type: 'text', text: JSON.stringify(names) }], stopReason: 'stop' } });
          })().catch(error => {
            send({ type: 'message_end', message: { role: 'assistant', content: [],
              stopReason: 'error', errorMessage: String(error) } });
          }).finally(() => { running = false; send({ type: 'agent_settled' }); });
          break;
        }
        if (command.message === 'dialog') {
          pendingDialog = true;
          send({ type: 'extension_ui_request', id: 'fixture-input', method: 'input', title: 'Official Pi dialog', placeholder: 'Enter text' });
          break;
        }
        if (command.message.startsWith('failure:')) {
          const mode = command.message.slice('failure:'.length);
          send({ type: 'message_start', message: { role: 'assistant', content: [] } });
          send({ type: 'message_end', message: { role: 'assistant', content: [], stopReason: 'error',
            errorMessage: mode === 'missing' ? '  ' : '429 配额不足\nPlease check your billing.' } });
          if (mode.startsWith('retry')) send({ type: 'auto_retry_end', success: false,
            ...(mode === 'retry-final' ? { finalError: '503 upstream unavailable' } : {}) });
          if (mode === 'recovered') {
            send({ type: 'message_end', message: { role: 'assistant', content: [], stopReason: 'stop' } });
            send({ type: 'auto_retry_end', success: true });
          }
          running = false; send({ type: 'agent_settled' }); break;
        }
        if (command.message === 'aa-codex') {
          send({ type: 'message_start', message: { role: 'assistant', api: 'openai-codex-responses', content: [] } });
          send({ type: 'message_update', assistantMessageEvent: { type: 'thinking_delta', contentIndex: 0, delta: 'A reasoning summary, not full reasoning tokens' } });
          let chunk = 0;
          const stream = () => {
            send({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 1, delta: '0123456789' } });
            if (++chunk < 10) { completion = setTimeout(stream, 100); return; }
            send({ type: 'message_end', message: { role: 'assistant', api: 'openai-codex-responses',
              content: [{ type: 'text', text: '0123456789'.repeat(10) }],
              usage: { input: 100, output: 600, reasoning: 500, cacheRead: 80, cacheWrite: 10, cost: { total: 0.012 } }, stopReason: 'stop' } });
            completion = setTimeout(() => { running = false; send({ type: 'agent_settled' }); }, 1500);
          };
          completion = setTimeout(stream, 500);
          break;
        }
        if (command.message === 'tool-image') {
          send({ type: 'tool_execution_start', toolCallId: 'image-1', toolName: 'generate_image', args: { prompt: 'fixture' } });
          send({ type: 'tool_execution_end', toolCallId: 'image-1', toolName: 'generate_image', result: { content: [
            { type: 'text', text: 'Generated image' },
            { type: 'image', mimeType: 'image/png', data: 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jL1cAAAAASUVORK5CYII=' },
          ] }, isError: false });
        }
        if (command.message === 'tools') {
          send({ type: 'tool_execution_start', toolCallId: 'tool-1', toolName: 'read', args: { path: 'fixture.txt' } });
          send({ type: 'tool_execution_update', toolCallId: 'tool-1', toolName: 'read', partialResult: { content: [{ type: 'text', text: 'partial' }] } });
          send({ type: 'tool_execution_end', toolCallId: 'tool-1', toolName: 'read', result: { content: [{ type: 'text', text: 'done\nsecond line\nthird line' }] }, isError: false });
          send({ type: 'tool_execution_start', toolCallId: 'code-1', toolName: 'codemode', args: { code: 'const value = 1;\ntext(value);' } });
          send({ type: 'tool_execution_start', toolCallId: 'nested-1', parentToolCallId: 'code-1', toolName: 'read', args: { path: 'nested.txt' } });
          send({ type: 'tool_execution_end', toolCallId: 'nested-1', parentToolCallId: 'code-1', toolName: 'read', result: { content: [{ type: 'text', text: 'nested output' }] }, isError: false });
          send({ type: 'tool_execution_end', toolCallId: 'code-1', toolName: 'codemode', result: {
            content: [{ type: 'text', text: 'Script completed\nOutput:\n1' }],
            nestedCalls: { complete: true, calls: [{ id: 'nested-1', name: 'read', arguments: { path: 'nested.txt' }, status: 'success' }] }
          }, isError: false });
        }
        send({ type: 'message_start', message: { role: 'assistant', content: [] } });
        const text = 'Reply: ' + command.message;
        send({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: text } });
        send({ type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text }], usage: { input: 100, output: 20, cacheRead: 80, cacheWrite: 10, cost: { total: 0.012 } }, stopReason: 'stop' } });
        send({ type: 'agent_end', willRetry: true, messages: [] });
        completion = setTimeout(() => { running = false; send({ type: 'agent_settled' }); }, command.message === 'slow' ? 1500 : 80);
        break;
      }
      default: send({ id: command.id, type: 'response', command: command.type, success: false, error: 'fixture rejected' });
    }
  }
});
process.stdin.on('end', () => { clearTimeout(completion); process.exit(0); });
