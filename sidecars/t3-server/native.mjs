// Pi Mac host policy only. T3 owns the engine, receipts, projections and reactors.
import { ServerOwnedPiDriver } from './pi-provider.mjs';
import { createConnectionDiagnostics } from './connection-diagnostics.mjs';
export const PiDriver = ServerOwnedPiDriver;
let host;
export function configureNative({ environmentId, directory }) {
  if (host && !host.closed) throw new Error('Server host already owned');
  host = { environmentId, closed: false, connectionDiagnostics: createConnectionDiagnostics(directory),
    diagnostics: { requests: 0, accepted: 0, queuedDeliveries: 0, successfulDeliveries: 0, failedDeliveries: 0 },
    message: '', browserURL: null, tunnelStatus: 'disabled', close() { this.closed = true; } };
  return host;
}
export function getNative() { if (!host) throw new Error('Server host unavailable'); return host; }
const methods = new Set(['server.probe', 'server.getConfig', 'server.getSettings', 'subscribeServerConfig', 'subscribeServerLifecycle',
  'orchestration.dispatchCommand', 'orchestration.subscribeShell', 'orchestration.subscribeThread', 'auth.subscribeAccess']);
export const rpcAllowed = method => methods.has(method);
export const httpAllowed = (method, url) => {
  const pathname = url.split('?')[0];
  return (method === 'GET' && (pathname === '/ws' || pathname === '/.well-known/t3/environment' || pathname.startsWith('/api/auth/') ||
    pathname === '/api/orchestration/shell' || /^\/api\/orchestration\/threads\/[^/]+$/.test(pathname) || pathname === '/api/connect/link-state')) ||
    (method === 'POST' && (pathname === '/oauth/token' || pathname.startsWith('/api/auth/') ||
      ['/api/orchestration/dispatch', '/api/t3-connect/health', '/api/t3-connect/mint-credential', '/api/connect/mint-credential', '/api/connect/preferences'].includes(pathname)));
};
export const nativeCapabilities = () => ({ repositoryIdentity: false, connectionProbe: true, attachmentUploads: true, agentActivityPublishing: false });
export function browserAuthorization(url) {
  const target = new URL(url);
  if (target.origin !== 'https://app.t3.codes' || target.pathname !== '/connect') throw new Error('Unexpected browser authorization');
  const broker = getNative(); broker.browserURL = url; broker.onBrowser?.(url);
}
export function recordPublish(response) {
  const broker = getNative(); broker.diagnostics.requests++; if (response.ok) broker.diagnostics.accepted++;
  for (const delivery of response.deliveries) {
    if (delivery.queued) broker.diagnostics.queuedDeliveries++;
    else if (delivery.ok) broker.diagnostics.successfulDeliveries++;
    else broker.diagnostics.failedDeliveries++;
  }
  broker.message = '官方 T3 Server 已接受活动更新；服务端统计不代表手机已显示通知。';
}
