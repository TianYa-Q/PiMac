import fs from 'node:fs';
import path from 'node:path';
import { randomBytes } from 'node:crypto';
import * as Effect from 'effect/Effect';
import * as Layer from 'effect/Layer';
import * as Logger from 'effect/Logger';
import * as Console from 'effect/Console';
import * as NodeServices from '@effect/platform-node/NodeServices';
import { runServer } from './upstream/apps/server/src/server.ts';
import { ServerConfig, deriveServerPaths, ensureServerDirectories } from './upstream/apps/server/src/config.ts';
import { DEFAULT_SIGNAL_EXPORT } from '@t3tools/shared/observability';
import * as OtelEnvironment from '@t3tools/shared/otelEnvironment';
import { configureNative } from './native.mjs';
import { configureAccountStatuses } from './account-status.mjs';
export { rpcAllowed, httpAllowed } from './native.mjs';
export { originAllowed } from './origin-policy.mjs';

function checkPrivateTree(directory, toolsDirectory, inTools = false) {
  const entries = fs.readdirSync(directory, { withFileTypes: true });
  for (const entry of entries) {
    const file = path.join(directory, entry.name), stat = fs.lstatSync(file);
    // Upstream extracts downloaded tools with archive permissions (usually 755).
    // They contain no credentials, but must still be owned by us, non-writable
    // by others, and never symlinks. Everything else remains private.
    const tool = inTools || file === toolsDirectory;
    const forbidden = tool ? 0o022 : 0o077;
    if ((!stat.isFile() && !stat.isDirectory()) || stat.uid !== process.getuid() || (stat.mode & forbidden)) throw new Error('Unsafe T3 Server state');
    if (stat.isDirectory()) checkPrivateTree(file, toolsDirectory, tool);
  }
}

export async function startPiServer({ directory, environmentId, onFailure, piConfig = {} }) {
  process.umask(0o077);
  fs.mkdirSync(directory, { mode: 0o700, recursive: true });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077)) throw new Error('Unsafe T3 Server directory');
  checkPrivateTree(directory, path.join(directory, 'tools'));
  const broker = configureNative({ environmentId, directory });
  configureAccountStatuses(directory);
  broker.controlToken = randomBytes(32).toString('hex');
  const configLayer = Layer.effect(ServerConfig, Effect.gen(function* () {
    const derived = yield* deriveServerPaths(directory, undefined, { baseDirIsExplicit: true });
    yield* ensureServerDirectories(derived);
    if (!fs.existsSync(derived.environmentIdPath)) fs.writeFileSync(derived.environmentIdPath, environmentId, { mode: 0o600, flag: 'wx' });
    if (fs.readFileSync(derived.environmentIdPath, 'utf8').trim() !== environmentId) throw new Error('Foreign T3 environment identity');
    if (!fs.existsSync(derived.settingsPath)) fs.writeFileSync(derived.settingsPath, JSON.stringify({
      providerInstances: { pi: { driver: 'pi', config: piConfig, enabled: true } }, enableProviderUpdateChecks: false,
      defaultThreadEnvMode: 'local', defaultRuntimeMode: 'full-access', defaultAutoPull: false,
      enableAgentBrowserAccess: false, enableAgentDeviceAccess: false,
    }), { mode: 0o600, flag: 'wx' });
    return { ...derived, mode: 'web', port: 0, host: '127.0.0.1', cwd: directory, baseDir: directory,
      logLevel: 'None', traceMinLevel: 'None', traceTimingEnabled: false, traceBatchWindowMs: 200,
      traceMaxBytes: 1024 * 1024, traceMaxFiles: 2,
      otlpTracesExport: DEFAULT_SIGNAL_EXPORT, otlpMetricsExport: DEFAULT_SIGNAL_EXPORT, otlpLogsExport: DEFAULT_SIGNAL_EXPORT, otelEnvironment: OtelEnvironment.none,
      staticDir: undefined, devUrl: undefined, devAllowedOrigins: [], noBrowser: true, startupPresentation: 'headless',
      autoBootstrapProjectFromCwd: false, logWebSocketEvents: false, tailscaleServeEnabled: false, tailscaleServePort: 443,
    };
  })).pipe(Layer.provide(NodeServices.layer));
  const quietConsole = new Proxy({}, { get: () => () => {} });
  const controller = new AbortController();
  let resolveManagement, rejectManagement, failed = false;
  const ready = new Promise((resolve, reject) => { resolveManagement = resolve; rejectManagement = reject; });
  broker.onManagementReady = resolveManagement;
  const program = runServer.pipe(Effect.provide(configLayer), Effect.provide(Logger.layer([])),
    Effect.provideService(Console.Console, quietConsole));
  const completion = Effect.runPromise(program, { signal: controller.signal }).catch(error => {
    if (!controller.signal.aborted) {
      if (process.env.PIMAC_T3_TEST_LOG_ERRORS === '1') process.stderr.write(String(error) + '\n');
      failed = true; rejectManagement(new Error('Official T3 Server failed')); onFailure?.();
    }
  });
  const timeout = setTimeout(() => rejectManagement(new Error('T3 Server startup timeout')), 60000);
  try {
    const management = await ready;
    for (let n = 0; n < 300; n++) {
      if (failed) throw new Error('Official T3 Server startup failed');
      const response = await fetch(management.localURL + '/.well-known/t3/environment', { signal: AbortSignal.timeout(2000) }).catch(() => null);
      if (response?.ok) return { management, broker, localURL: management.localURL, close: async () => { controller.abort(); await completion; broker.close(); } };
      await new Promise(resolve => setTimeout(resolve, 100));
    }
    throw new Error('T3 Server routes unavailable');
  } catch (error) { controller.abort(); await completion; broker.close(); throw error; }
  finally { clearTimeout(timeout); }
}
