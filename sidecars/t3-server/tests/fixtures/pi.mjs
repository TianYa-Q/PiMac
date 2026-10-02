// Protocol-only fixture: never calls a model, network, shell or real Pi.
import fs from 'node:fs';
import path from 'node:path';
import { StringDecoder } from 'node:string_decoder';
const args = process.argv.slice(2);
const option = name => args[args.indexOf(name) + 1];
const sessionId = args.includes('--session-id') ? option('--session-id') : undefined;
const directory = args.includes('--session-dir') ? option('--session-dir') : undefined;
if (directory) fs.mkdirSync(directory, { recursive: true, mode: 0o700 });
const file = directory && path.join(directory, sessionId + '.jsonl');
let model = { provider: 'test', id: 'model', name: 'Test Model', reasoning: true,
  thinkingLevelMap: { xhigh: 'xhigh', max: 'max' }, contextWindow: 10000 }, running = false, completion;
let thinkingLevel = 'off';
const send = value => process.stdout.write(JSON.stringify(value) + '\r\n');
const decoder = new StringDecoder('utf8'); let buffer = '';
process.stdin.on('data', chunk => {
  buffer += decoder.write(chunk); let end;
  while ((end = buffer.indexOf('\n')) !== -1) {
    const command = JSON.parse(buffer.slice(0, end)); buffer = buffer.slice(end + 1);
    if (file) fs.appendFileSync(file, JSON.stringify({ command: command.type, message: command.message, sessionId,
      secretInherited: !!process.env.PIMAC_T3_BRIDGE_TOKEN }) + '\n', { mode: 0o600 });
    const response = data => send({ id: command.id, type: 'response', command: command.type, success: true, ...(data ? { data } : {}) });
    switch (command.type) {
      case 'get_state': response({ sessionId, isStreaming: running, model, thinkingLevel }); break;
      case 'get_session_stats': response({ tokens: { input: 100, output: 20, cacheRead: 80, cacheWrite: 0, total: 200 },
        cost: 0.012, contextUsage: { tokens: 200, contextWindow: 10000, percent: 2 } }); break;
      case 'get_available_models': response({ models: [model] }); break;
      case 'set_model': model = { provider: command.provider, id: command.modelId, name: command.modelId }; response(model); break;
      case 'set_thinking_level': thinkingLevel = command.level; response(); break;
      case 'set_session_name': case 'clear_queue': response(); break;
      case 'extension_ui_response': break;
      case 'abort':
        clearTimeout(completion); running = false; send({ type: 'agent_settled' }); response(); break;
      case 'prompt': {
        if (command.message === 'exit') { process.exit(3); }
        if (command.message === 'no-response') break;
        response({ disposition: command.message === '/handled' ? 'handled' : 'started' });
        if (command.message === '/handled') break;
        running = true; send({ type: 'agent_start' });
        if (command.message === 'wait') break;
        if (command.message === 'tools') {
          send({ type: 'tool_execution_start', toolCallId: 'tool-1', toolName: 'read', args: { path: 'fixture.txt' } });
          send({ type: 'tool_execution_update', toolCallId: 'tool-1', toolName: 'read', partialResult: { content: [{ type: 'text', text: 'partial' }] } });
          send({ type: 'tool_execution_end', toolCallId: 'tool-1', toolName: 'read', result: { content: [{ type: 'text', text: 'done' }] }, isError: false });
        }
        send({ type: 'message_start', message: { role: 'assistant', content: [] } });
        const text = 'Reply: ' + command.message;
        send({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', contentIndex: 0, delta: text } });
        send({ type: 'message_end', message: { role: 'assistant', content: [{ type: 'text', text }], usage: { output: 20 }, stopReason: 'stop' } });
        send({ type: 'agent_end', willRetry: true, messages: [] });
        completion = setTimeout(() => { running = false; send({ type: 'agent_settled' }); }, command.message === 'slow' ? 1500 : 80);
        break;
      }
      default: send({ id: command.id, type: 'response', command: command.type, success: false, error: 'fixture rejected' });
    }
  }
});
process.stdin.on('end', () => { clearTimeout(completion); process.exit(0); });
