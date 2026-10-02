// Adapted from pingdotgg/t3code packages/contracts/src/auth.ts and environment.ts.
// Baseline a97a4a9d189f145afe79c3a6f8533bbf9a6b40b1. See T3-LICENSE.txt.
export const TOKEN_EXCHANGE_GRANT = 'urn:ietf:params:oauth:grant-type:token-exchange';
export const BOOTSTRAP_TOKEN_TYPE = 'urn:t3:params:oauth:token-type:environment-bootstrap';
export const ACCESS_TOKEN_TYPE = 'urn:ietf:params:oauth:token-type:access_token';
export const SCOPES = Object.freeze([
  'orchestration:read', 'orchestration:operate', 'terminal:operate', 'review:write',
  'access:read', 'access:write', 'relay:read', 'relay:write',
]);
// Unmodified iOS explicitly requests AuthStandardClientScopes during onboarding.
// Permission scopes do not advertise feature support; unsupported RPCs must still fail closed.
export const DEFAULT_SCOPES = Object.freeze([
  'orchestration:read', 'orchestration:operate', 'terminal:operate', 'review:write', 'relay:read',
]);
export const AUTH_DESCRIPTOR = Object.freeze({
  policy: 'remote-reachable', bootstrapMethods: ['one-time-token'],
  sessionMethods: ['bearer-access-token'], sessionCookieName: 'pimac_t3_session',
});
export function environmentDescriptor(environmentId) {
  return {
    environmentId, label: 'Pi Mac',
    platform: { os: process.platform === 'darwin' ? 'darwin' : 'unknown',
      arch: ['arm64', 'x64'].includes(process.arch) ? process.arch : 'other' },
    // Do not impersonate a released T3 backend version.
    serverVersion: 'pimac-t3-preview-1', orchestrationProtocolVersion: 1,
    capabilities: { repositoryIdentity: false, agentActivityPublishing: false },
  };
}
