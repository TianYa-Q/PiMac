// Test-only credential/runtime isolation. Production keeps all official drivers and capabilities.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const nativeDrivers = ['codex', 'claudeAgent', 'cursor', 'grok', 'opencode', 'antigravity', 'muse', 'acpRegistry'];
const nativeExecutables = ['codex', 'claude', 'cursor', 'cursor-agent', 'agent', 'grok', 'opencode', 'antigravity', 'muse', 'pi'];
const inheritedKeys = ['PATH', 'TMPDIR', 'TMP', 'TEMP', 'LANG', 'LC_ALL', 'TZ', 'SystemRoot', 'WINDIR'];

export function fixtureEnvironment(directory, source) {
  const home = path.join(directory, 'fixture-home');
  return {
    ...Object.fromEntries(inheritedKeys.filter(key => source[key] !== undefined).map(key => [key, source[key]])),
    PATH: path.join(directory, 'fixture-bin') + path.delimiter + (source.PATH ?? ''),
    HOME: home, USERPROFILE: home,
    CODEX_HOME: path.join(home, 'codex'), CLAUDE_CONFIG_DIR: path.join(home, 'claude'),
    GROK_HOME: path.join(home, 'grok'), PI_CODING_AGENT_DIR: path.join(home, 'pi', 'agent'),
    PI_CODING_AGENT_PACKAGE_DIR: path.join(home, 'pi', 'package'),
    XDG_CONFIG_HOME: path.join(home, 'config'), XDG_DATA_HOME: path.join(home, 'data'),
    XDG_STATE_HOME: path.join(home, 'state'), XDG_CACHE_HOME: path.join(home, 'cache'),
  };
}

export function prepareProtocolServer(directory, piConfig, model = 'test/model') {
  const environment = fixtureEnvironment(directory, process.env);
  const bin = path.join(directory, 'fixture-bin');
  fs.mkdirSync(bin, { recursive: true, mode: 0o700 });
  // 即使禁用实例后有探测回归，也只命中本地拒绝 fixture 并记录证据；
  // 绝不探测开发者二进制，更不能意外启动真实 app-server/模型。
  const probeLog = path.join(directory, 'fixture-native-probes.log').replaceAll("'", "'\\''");
  for (const name of nativeExecutables) {
    fs.writeFileSync(path.join(bin, name), `#!/bin/sh\nprintf '%s\\n' '${name}'\" $*\" >> '${probeLog}'\nexit 127\n`, { mode: 0o700 });
  }
  for (const [key, value] of Object.entries(environment)) {
    if (key.endsWith('_HOME') || key.endsWith('_DIR') || key === 'HOME' || key === 'USERPROFILE') {
      fs.mkdirSync(value, { recursive: true, mode: 0o700 });
    }
  }
  // Swift 的 Server 继承宿主环境，不能为并行测试全局 setenv；实例环境显式清空
  // 非允许项并覆盖所有 home，确保 fixture Provider 也不读取开发者凭据/扩展。
  const providerEnvironment = Object.entries({
    ...Object.fromEntries(Object.keys(process.env).map(key => [key, ''])), ...environment,
  }).map(([name, value]) => ({ name, value, sensitive: false }));
  const selection = { instanceId: 'pi', model };
  const settings = {
    providerInstances: {
      ...Object.fromEntries(nativeDrivers.map(driver => [driver, { driver, enabled: false }])),
      pi: { driver: 'pi', enabled: piConfig.enabled !== false && !!piConfig.binaryPath,
        config: piConfig, environment: providerEnvironment },
    },
    defaultModelSelection: selection, textGenerationModelSelection: selection,
    sourceControlWriterModelSelection: selection,
    defaultThreadEnvMode: 'local', defaultRuntimeMode: 'full-access', defaultAutoPull: false,
    enableProviderUpdateChecks: false,
  };
  const state = path.join(directory, 'server-owned', 'userdata');
  fs.mkdirSync(state, { recursive: true, mode: 0o700 });
  const file = path.join(state, 'settings.json');
  // 重启测试必须沿用服务端已写回的状态，不能重置模型偏好/认证或掩盖持久化回归。
  try { fs.writeFileSync(file, JSON.stringify(settings), { mode: 0o600, flag: 'wx' }); }
  catch (error) { if (error.code !== 'EEXIST') throw error; }
  return environment;
}

export async function createServerGateway(options) {
  const previous = { ...process.env };
  const environment = prepareProtocolServer(options.directory, options.piConfig ?? {});
  const replaceEnvironment = next => {
    for (const key of Object.keys(process.env)) delete process.env[key];
    Object.assign(process.env, next);
  };
  replaceEnvironment(environment);
  try {
    const { createServerGateway: create } = await import('../../../../Sources/PiMacApp/Resources/t3-bridge/server-gateway.mjs');
    const gateway = await create(options);
    let closed = false;
    return { ...gateway, close: async () => {
      if (closed) return;
      closed = true;
      try { await gateway.close(); } finally { replaceEnvironment(previous); }
    } };
  } catch (error) { replaceEnvironment(previous); throw error; }
}

// Swift fixture preparation only; this branch never imports or starts the Server.
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  if (process.argv[2] !== '--prepare' || process.argv.length !== 6) throw new Error('Expected --prepare STATE BINARY MODEL');
  console.log(JSON.stringify(prepareProtocolServer(process.argv[3], process.argv[4] ? { binaryPath: process.argv[4] } : { enabled: false }, process.argv[5])));
}
