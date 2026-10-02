import { createTwoFilesPatch } from 'diff';

// Preserve Pi's edit details in official V2 file_change items, including the
// proposed replacement while the tool is running. Never read the workspace:
// it may already contain later edits by the time a snapshot is rendered.
export function piFileChangeDetails(toolName, args, result) {
  const diff = result?.details?.diff;
  if (typeof diff === 'string' && diff.length > 0) return { diffStr: diff };
  const path = args?.path ?? args?.file_path ?? 'file';
  if (toolName === 'write' && typeof args?.content === 'string') {
    return { newStr: args.content };
  }
  const edits = Array.isArray(args?.edits) ? args.edits : [args];
  const patches = edits.flatMap(edit => {
    if (typeof edit?.oldText !== 'string' || typeof edit?.newText !== 'string') return [];
    return [createTwoFilesPatch(path, path, edit.oldText, edit.newText)];
  });
  return patches.length > 0 ? { diffStr: patches.join('\n') } : {};
}
