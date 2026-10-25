// Pi Mac host integration only. T3 owns the engine, permissions and runtime capabilities.
import { createConnectionDiagnostics } from './connection-diagnostics.mjs';
import { createPiMobileUsage } from './pi-mobile-usage.mjs';
import { createTunnelHealth } from './tunnel-health.mjs';
import { createPiAccountSelections } from './pi-account-selection.mjs';
let host;
export function configureNative({ environmentId, directory, accounts }) {
  if (host && !host.closed) throw new Error('Server host already owned');
  const connectionDiagnostics = createConnectionDiagnostics(directory);
  host = { environmentId, directory, closed: false, accountSelections: createPiAccountSelections(), mobileUsage: createPiMobileUsage({ accounts }), connectionDiagnostics,
    tunnelHealth: createTunnelHealth(connectionDiagnostics),
    diagnostics: { requests: 0, accepted: 0, queuedDeliveries: 0, successfulDeliveries: 0, failedDeliveries: 0 },
    message: '', browserURL: null, close() { this.closed = true; this.mobileUsage.close(); this.accountSelections.close(); } };
  return host;
}
export function getNative() { if (!host) throw new Error('Server host unavailable'); return host; }
export function browserAuthorization(url) {
  const target = URL.parse(url);
  // 仅接管桌面发起的 T3 登录；其他 Provider 授权和普通链接继续走官方启动器。
  if (target?.origin !== 'https://app.t3.codes' || target.pathname !== '/connect') return false;
  const broker = getNative();
  if (!broker.onBrowser) return false;
  broker.browserURL = url; broker.onBrowser(url);
  return true;
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
