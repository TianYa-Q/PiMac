import * as Schema from 'effect/Schema';
import { ServerConfig } from './upstream/server.ts';
import { ServerSettings } from './upstream/settings.ts';
import { AUTH_DESCRIPTOR, environmentDescriptor } from '../../Sources/PiMacApp/Resources/t3-bridge/protocol.mjs';

const defaults = Schema.encodeSync(ServerSettings)(Schema.decodeUnknownSync(ServerSettings)({}));
export function previewServerConfig(environmentId, models = [], defaultModelId = null, agentActivityPublishing = false) {
  // Real native Pi model IDs, not fake Codex/Claude driver instances.
  // Reads never launch a runtime, expose credentials or enable provider management.
  // Never mistake discovery/tab order or an existing session's model for the
  // native new-session preference. Hidden/unavailable defaults stay unselected.
  const selection = models.some(model => model.id === defaultModelId)
    ? { instanceId: 'pi', model: defaultModelId } : null;
  const providers = models.length ? [{
    instanceId: 'pi', driver: 'pi', displayName: 'Pi', enabled: true, installed: true,
    version: null, status: 'ready', availability: 'available',
    auth: { status: 'unknown' }, checkedAt: '1970-01-01T00:00:00.000Z',
    setup: { canAuthenticate: false, canInstall: false },
    showInteractionModeToggle: false, supportsTextGeneration: false,
    supportsConversationRollback: false, requiresNewThreadForModelChange: false,
    models: models.map(model => ({
      slug: model.id, name: model.name || model.id, subProvider: model.provider,
      isCustom: false, isDefault: selection?.model === model.id,
      capabilities: { optionDescriptors: [] },
    })),
  }] : [];
  return Schema.decodeUnknownSync(ServerConfig)({
    environment: { ...environmentDescriptor(environmentId), capabilities: {
      repositoryIdentity: false, connectionProbe: true, attachmentUploads: false,
      agentActivityPublishing, environmentThemes: false, usageLimitSources: false,
    } },
    auth: AUTH_DESCRIPTOR, cwd: '/', keybindingsConfigPath: 'pimac://unsupported-keybindings',
    keybindings: [], issues: [], providers, availableEditors: [], remoteOpenTargets: [],
    observability: { logsDirectoryPath: 'pimac://disabled-logs', localTracingEnabled: false,
      otlpTracesEnabled: false, otlpMetricsEnabled: false, otlpLogsEnabled: false },
    settings: { ...defaults, providerInstances: {}, enableProviderUpdateChecks: false,
      defaultModelSelection: selection, defaultRuntimeMode: 'full-access',
      defaultThreadEnvMode: 'local', enableAgentDeviceAccess: false,
      enableAgentBrowserAccess: false },
    shellResumeCompletionMarker: true, threadResumeCompletionMarker: true,
    threadSnapshotPagination: false, reasoningMessages: true,
  });
}
