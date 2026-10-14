// Pi Mac host policy only. T3 owns the engine, receipts, projections and reactors.
import { createConnectionDiagnostics } from './connection-diagnostics.mjs';
import { createPiMobileUsage } from './pi-mobile-usage.mjs';
import { createTunnelHealth } from './tunnel-health.mjs';
import { createPiAccountSelections } from './pi-account-selection.mjs';
let host;
export function configureNative({ environmentId, directory }) {
  if (host && !host.closed) throw new Error('Server host already owned');
  const connectionDiagnostics = createConnectionDiagnostics(directory);
  host = { environmentId, closed: false, accountSelections: createPiAccountSelections(), mobileUsage: createPiMobileUsage(), connectionDiagnostics,
    tunnelHealth: createTunnelHealth(connectionDiagnostics),
    diagnostics: { requests: 0, accepted: 0, queuedDeliveries: 0, successfulDeliveries: 0, failedDeliveries: 0 },
    message: '', browserURL: null, close() { this.closed = true; this.mobileUsage.close(); this.accountSelections.close(); } };
  return host;
}
export function getNative() { if (!host) throw new Error('Server host unavailable'); return host; }
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
