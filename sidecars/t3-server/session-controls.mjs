// Private, server-owned runtime controls. Never accepts arbitrary Pi commands.
const controls = new Map();
export function registerSessionControls(threadId, control) {
  controls.set(threadId, control);
  return () => { if (controls.get(threadId) === control) controls.delete(threadId); };
}
export async function controlSession(threadId, operation, accountName, modelSelection) {
  if (typeof threadId !== 'string' || !['compact', 'switch-account', 'abort-compaction'].includes(operation)) throw new Error('Invalid session control');
  if (operation === 'switch-account' && !/^[A-Za-z0-9._-]{1,64}$/.test(accountName ?? '')) throw new Error('Invalid account name');
  const control = controls.get(threadId);
  if (!control) throw new Error('No live Pi runtime; send a message first');
  return control(operation, accountName, modelSelection);
}
