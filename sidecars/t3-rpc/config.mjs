import * as Schema from 'effect/Schema';
import { ServerConfig } from './upstream/server.ts';
import { ServerSettings } from './upstream/settings.ts';
import { AUTH_DESCRIPTOR, environmentDescriptor } from '../../Sources/PiMacApp/Resources/t3-bridge/protocol.mjs';

const defaults = Schema.encodeSync(ServerSettings)(Schema.decodeUnknownSync(ServerSettings)({}));
export function previewServerConfig(environmentId) {
  // No fake Codex/Claude driver, credentials or provider-install capability.
  // Pi remains owned by the desktop. Existing-thread sends use native shared
  // runtimes, not an invented T3 provider. Upload endpoints remain unsupported.
  return Schema.decodeUnknownSync(ServerConfig)({
    environment: { ...environmentDescriptor(environmentId), capabilities: {
      repositoryIdentity: false, connectionProbe: true, attachmentUploads: false,
      agentActivityPublishing: false, environmentThemes: false, usageLimitSources: false,
    } },
    auth: AUTH_DESCRIPTOR, cwd: '/', keybindingsConfigPath: 'pimac://unsupported-keybindings',
    keybindings: [], issues: [], providers: [], availableEditors: [], remoteOpenTargets: [],
    observability: { logsDirectoryPath: 'pimac://disabled-logs', localTracingEnabled: false,
      otlpTracesEnabled: false, otlpMetricsEnabled: false, otlpLogsEnabled: false },
    settings: { ...defaults, providerInstances: {}, enableProviderUpdateChecks: false,
      enableAgentBrowserAccess: false },
    shellResumeCompletionMarker: true, threadResumeCompletionMarker: true,
    threadSnapshotPagination: false, reasoningMessages: true,
  });
}
