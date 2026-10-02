import { createHash } from 'node:crypto';
import { OrchestrationDispatchCommandError } from './upstream/orchestration.ts';

const fail = message => new OrchestrationDispatchCommandError({ message });
const identifier = value => typeof value === 'string' && value.length > 0 && value.length <= 128;
const imageLimit = 8 * 1024 * 1024;

// No caller-supplied paths, attachment URLs, or bootstrap workspace roots cross IPC.
export function validateSend(input) {
  if (!input || input.type !== 'thread.turn.start' || !identifier(input.commandId) ||
      !identifier(input.threadId) || !identifier(input.message?.messageId) ||
      input.message.role !== 'user' || typeof input.message.text !== 'string' ||
      Buffer.byteLength(input.message.text) > 256 * 1024 ||
      !Array.isArray(input.message.attachments) || input.message.attachments.length > 8 ||
      input.bootstrap || input.sourceProposedPlan || input.message.context ||
      (input.runtimeMode !== undefined && input.runtimeMode !== 'full-access') ||
      (input.interactionMode !== undefined && input.interactionMode !== 'default') ||
      (input.modelSelection !== undefined && (!identifier(input.modelSelection?.instanceId) || !identifier(input.modelSelection?.model)))) {
    throw fail('Unsupported or invalid message command. No message was sent.');
  }
  let bytes = 0;
  const images = input.message.attachments.map(attachment => {
    if (attachment?.type !== 'image' || !['image/png', 'image/jpeg', 'image/webp'].includes(attachment.mimeType) ||
        typeof attachment.dataUrl !== 'string' || !attachment.dataUrl.startsWith(`data:${attachment.mimeType};base64,`)) {
      throw fail('Only inline PNG, JPEG and WebP images are supported. No message was sent.');
    }
    const encoded = attachment.dataUrl.slice(attachment.dataUrl.indexOf(',') + 1);
    if (!encoded.length || encoded.length > Math.ceil(imageLimit / 3) * 4 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
      throw fail('Invalid or oversized image. No message was sent.');
    }
    const data = Buffer.from(encoded, 'base64');
    bytes += data.length;
    if (data.toString('base64') !== encoded || data.length !== attachment.sizeBytes || bytes > imageLimit) {
      throw fail('Invalid or oversized image. No message was sent.');
    }
    return { mimeType: attachment.mimeType, data: encoded };
  });
  if (!input.message.text.trim() && !images.length) throw fail('Message is empty. No message was sent.');
  return { type: input.type, commandId: input.commandId, threadId: input.threadId,
    message: { messageId: input.message.messageId, role: 'user', text: input.message.text, attachments: [] },
    ...(input.modelSelection ? { modelSelection: { instanceId: input.modelSelection.instanceId, model: input.modelSelection.model } } : {}), images };
}

// Retain outcomes (including uncertain failures) rather than evict and risk a
// resend on a reconnect. Capacity exhaustion fails closed until bridge restart.
export class CommandDispatcher {
  constructor(workspace, capacity = 256) { this.workspace = workspace; this.capacity = capacity; this.commands = new Map(); }
  dispatch(input, owner, signal) {
    let command;
    try { command = validateSend(input); } catch (error) { return Promise.reject(error); }
    const key = `${owner}:${command.commandId}`;
    const signature = createHash('sha256').update(JSON.stringify(command)).digest('hex');
    const existing = this.commands.get(key);
    if (existing) return existing.signature === signature ? existing.result : Promise.reject(fail('Command ID was reused with different content.'));
    if (!this.workspace || this.commands.size >= this.capacity) return Promise.reject(fail('Message sending is unavailable or at capacity. No message was sent.'));
    const nativeCommand = { ...command, commandId: createHash('sha256').update(key).digest('hex') };
    const result = this.workspace.dispatch(nativeCommand, signal).catch(error => {
      if (error.code === 'sending_disabled') {
        this.commands.delete(key); // Definitive pre-submit refusal, safe to retry after consent.
        throw fail('请在 Pi Mac 的 T3 设置开启「允许手机发送消息」。这条消息未发送。');
      }
      throw fail('Pi did not confirm message acceptance. Check this conversation before retrying.');
    });
    this.commands.set(key, { signature, result });
    return result;
  }
}
