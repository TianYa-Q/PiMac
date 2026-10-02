import os from 'node:os';
import { isIPv4 } from 'node:net';

export function isPrivateAddress(host) {
  if (!isIPv4(host)) return false;
  const [a, b] = host.split('.').map(Number);
  return a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168);
}
export function validatePublicEndpoint(endpoint, interfaces = os.networkInterfaces()) {
  if (!endpoint || (endpoint.host !== '127.0.0.1' && !isPrivateAddress(endpoint.host)) ||
      !Number.isInteger(endpoint.port) || endpoint.port < 1024 || endpoint.port > 65535 ||
      !Object.values(interfaces).flat().some(item => item?.address === endpoint.host)) {
    throw new Error('A local private IPv4 address and unprivileged port are required');
  }
  return endpoint;
}
export const isLoopbackPeer = address => address === '127.0.0.1' || address === '::1' || address === '::ffff:127.0.0.1';
