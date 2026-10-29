import fs from 'node:fs';
import path from 'node:path';
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
import { migratePiSettings, migrateProviderDiscoverySettings } from './settings-migration.mjs';
import { BUILT_IN_DRIVERS } from './upstream/apps/server/src/provider/builtInDrivers.ts';
import { prepareServerPort } from './server-port.mjs';
export { originAllowed } from './origin-policy.mjs';
export { createAccountRuntime } from './account-runtime.ts';

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

export async function startPiServer({ directory, environmentId, onFailure, piConfig = {}, signal, accounts, shellEnvironmentPrepared = false }) {
  process.umask(0o077);
  // Supervisor credentials have already been captured by the gateway. They
  // must not enter upstream's inherited environment or any provider subprocess.
  for (const key of Object.keys(process.env)) {
    if (key.startsWith('PIMAC_T3_') && key !== 'PIMAC_T3_TEST_LOG_ERRORS') delete process.env[key];
  }
  fs.mkdirSync(directory, { mode: 0o700, recursive: true });
  const stat = fs.lstatSync(directory);
  if (!stat.isDirectory() || stat.uid !== process.getuid() || (stat.mode & 0o077)) throw new Error('Unsafe T3 Server directory');
  const broker = configureNative({ environmentId, directory, accounts });
  let binding;
  try {
    broker.startup.record('state.permissions', 'start', null);
    checkPrivateTree(directory, path.join(directory, 'tools'));
    broker.startup.record('state.permissions', 'success', null);
    binding = await prepareServerPort(directory, broker.connectionDiagnostics);
  } catch (error) { broker.close(); throw error; }
  const configLayer = Layer.effect(ServerConfig, Effect.gen(function* () {
    const derived = yield* deriveServerPaths(directory, undefined, { baseDirIsExplicit: true });
    yield* ensureServerDirectories(derived);
    if (!fs.existsSync(derived.environmentIdPath)) fs.writeFileSync(derived.environmentIdPath, environmentId, { mode: 0o600, flag: 'wx' });
    if (fs.readFileSync(derived.environmentIdPath, 'utf8').trim() !== environmentId) throw new Error('Foreign T3 environment identity');
    migratePiSettings(derived.settingsPath, piConfig);
    const providerDefaults = Object.fromEntries(BUILT_IN_DRIVERS
      .filter(driver => driver.metadata.hasDefaultInstance !== false)
      .map(driver => [driver.driverKind, { driver: driver.driverKind, enabled: driver.driverKind === 'pi',
        ...(driver.driverKind === 'pi' ? { config: piConfig } : {}) }]));
    if (!fs.existsSync(derived.settingsPath)) fs.writeFileSync(derived.settingsPath, JSON.stringify({
      providerInstances: providerDefaults,
      // 能力开关沿用官方默认值及用户设置；实例发现默认仅 Pi，可在官方设置重新启用。
      defaultThreadEnvMode: 'local', defaultRuntimeMode: 'full-access', defaultAutoPull: false,
    }), { mode: 0o600, flag: 'wx' });
    migrateProviderDiscoverySettings(derived.settingsPath, providerDefaults);
    // 不继承官方桌面启动器的凭据、FD 或开发认证；PiMac 仍以仅回环的 web
    // 服务运行。显式列出可选集成入口，避免上游新增桌面能力时误接宿主资源。
    return ServerConfig.of({ ...derived, mode: 'web', port: binding.port, host: '127.0.0.1', cwd: directory, baseDir: directory,
      logLevel: 'None', traceMinLevel: 'None', traceTimingEnabled: false, traceBatchWindowMs: 200,
      traceMaxBytes: 1024 * 1024, traceMaxFiles: 2,
      otlpTracesUrl: undefined, otlpMetricsUrl: undefined, otlpLogsUrl: undefined,
      otlpTracesExport: DEFAULT_SIGNAL_EXPORT, otlpMetricsExport: DEFAULT_SIGNAL_EXPORT, otlpLogsExport: DEFAULT_SIGNAL_EXPORT, otelEnvironment: OtelEnvironment.none,
      desktopBootstrapToken: undefined, desktopBootstrapSecret: undefined,
      desktopTelemetryFd: undefined, desktopTelemetryControlFd: undefined,
      desktopBrowserFd: undefined, desktopBrowserControlFd: undefined, resourceMonitorPath: undefined,
      shellEnvironmentPrepared,
      staticDir: undefined, devUrl: undefined, devAuthToken: undefined, devAllowedOrigins: [], noBrowser: true, startupPresentation: 'headless',
      autoBootstrapProjectFromCwd: false, logWebSocketEvents: false, tailscaleServeEnabled: false, tailscaleServePort: 443,
    });
  })).pipe(Layer.provide(NodeServices.layer));
  const quietConsole = new Proxy({}, { get: () => () => {} });
  const controller = new AbortController();
  let resolveManagement, rejectManagement, management, commandReady = false;
  // management layer/HTTP 监听可以早于恢复完成；必须同时等到官方 command gate 开放。
  const publishReady = () => { if (management && commandReady) resolveManagement(management); };
  const ready = new Promise((resolve, reject) => { resolveManagement = resolve; rejectManagement = reject; });
  const cancel = () => {
    rejectManagement(new Error('T3 Server startup cancelled'));
    controller.abort();
  };
  signal?.addEventListener('abort', cancel, { once: true });
  if (signal?.aborted) cancel();
  broker.onManagementReady = value => {
    try {
      binding.commit(Number(new URL(value.localURL).port));
      broker.startup.record('management.available', 'success', null);
      management = value;
      publishReady();
    } catch (error) { rejectManagement(error); }
  };
  broker.onCommandReady = () => {
    broker.startup.record('commands.ready', 'success', null);
    commandReady = true;
    publishReady();
  };
  // 新版 ProcessRunner 在构造外层服务时就获取 ChildProcessSpawner；仅在
  // configLayer 或上游内部提供平台层太晚，必须同时覆盖 runServer 的启动边界。
  const program = runServer.pipe(Effect.provide(configLayer), Effect.provide(NodeServices.layer), Effect.provide(Logger.layer([])),
    Effect.provideService(Console.Console, quietConsole));
  broker.startup.record('runtime.launch', 'start', null);
  const completion = Effect.runPromise(program, { signal: controller.signal }).catch(error => {
    if (!controller.signal.aborted) {
      if (process.env.PIMAC_T3_TEST_LOG_ERRORS === '1') process.stderr.write(String(error) + '\n');
      rejectManagement(new Error('Official T3 Server failed')); onFailure?.();
    }
  });
  const timeout = setTimeout(() => rejectManagement(new Error('T3 Server startup timeout')), 60000);
  try {
    const management = await ready;
    broker.startup.record('server.ready', 'success', null);
    return { management, broker, localURL: management.localURL, close: async () => { controller.abort(); await completion; broker.close(); } };
  } catch (error) {
    broker.startup.record('server.ready', 'failure', null);
    controller.abort(); await completion; broker.close(); throw error;
  }
  finally { clearTimeout(timeout); signal?.removeEventListener('abort', cancel); }
}
