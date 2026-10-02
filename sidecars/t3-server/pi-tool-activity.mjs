// Pi's desktop uses expanded tool details, not T3's one-line activity previews.
// Bound display payloads explicitly without silently replacing output by its first line.
export const MAX_TOOL_OUTPUT_CHARS = 200_000;
export function projectPiToolActivityData(data) {
  const projected = { piTool: true, toolName: data.toolName, toolCallId: data.toolCallId };
  for (const key of ['input', 'command', 'parentToolCallId', 'nestedCalls', 'diff']) {
    if (data[key] !== undefined) projected[key] = data[key];
  }
  const content = data.rawOutput?.content;
  if (typeof content === 'string') {
    projected.rawOutput = { content: content.length > MAX_TOOL_OUTPUT_CHARS
      ? content.slice(0, MAX_TOOL_OUTPUT_CHARS) + '\n\n[显示内容已截断：超过 200,000 字符]'
      : content };
  }
  return projected;
}
