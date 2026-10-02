// Only the official CLI's dedicated loopback listener may serve OAuth callbacks.
// State/code validation remains the responsibility of its upstream route.
export function loopbackOAuthCallbackAllowed(request) {
  const socket = request.source?.socket;
  return request.headers.origin === undefined && request.method === 'GET' &&
    request.url.split('?')[0] === '/callback' &&
    socket?.localAddress === '127.0.0.1' && socket.localPort === 34338 &&
    socket.remoteAddress === '127.0.0.1';
}
