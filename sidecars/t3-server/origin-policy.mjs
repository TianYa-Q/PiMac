// Native WebSocket clients may send their endpoint's HTTP Origin.
// Keep browser-bearing ordinary HTTP and cross-origin upgrades denied.
export function originAllowed(method, url, headers) {
  if (headers.origin === undefined) return true;
  if (method !== 'GET' || url.split('?')[0] !== '/ws' ||
      headers.upgrade?.toLowerCase() !== 'websocket') return false;
  try {
    const origin = new URL(headers.origin);
    // Cloudflare terminates TLS and forwards the original scheme to the
    // loopback listener. LAN strips forwarding headers in server-gateway.
    const protocol = headers['x-forwarded-proto'] === 'https' ? 'https' : 'http';
    const endpoint = new URL(`${protocol}://${headers.host}`);
    return origin.origin === endpoint.origin && origin.pathname === '/' &&
      !origin.search && !origin.hash && !origin.username && !origin.password;
  } catch { return false; }
}
