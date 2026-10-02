// Test-only, unchanged upstream schema closure at the pinned T3 commit.
import * as Schema from 'effect/Schema';
import { OrchestrationShellSnapshot, OrchestrationThreadDetailSnapshot, OrchestrationRpcSchemas } from './upstream/orchestration.ts';
import { ServerConfig, ServerConfigStreamEvent, ServerLifecycleStreamEvent } from './upstream/server.ts';
export const encodeConfig = Schema.encodeSync(ServerConfig);
export const encodeConfigEvent = Schema.encodeSync(ServerConfigStreamEvent);
export const encodeLifecycle = Schema.encodeSync(ServerLifecycleStreamEvent);
export const validateShell = Schema.decodeUnknownSync(OrchestrationShellSnapshot);
export const validateThread = Schema.decodeUnknownSync(OrchestrationThreadDetailSnapshot);
export const validateShellInput = Schema.decodeUnknownSync(OrchestrationRpcSchemas.subscribeShell.input);
export const validateShellItem = Schema.decodeUnknownSync(OrchestrationRpcSchemas.subscribeShell.output);
