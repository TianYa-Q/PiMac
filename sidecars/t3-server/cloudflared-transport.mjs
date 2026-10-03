// A fresh auto/QUIC connector can spend minutes retrying blocked UDP before
// falling back. Pin only this child to HTTP/2; do not alter Pi/relay traffic.
export function cloudflaredEnvironment(environment, connectorToken) {
  return { ...environment,
    TUNNEL_TRANSPORT_PROTOCOL: 'http2',
    TUNNEL_TOKEN: connectorToken };
}
