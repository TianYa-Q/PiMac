import type { Server } from "node:http";
import type { createAccountRuntime } from "../../account-runtime.js";

// Fixture 的类型边界不解析数 MB 的生成 bundle；真实 Server 行为由集成测试执行。
export const nativeDrivers: readonly string[];
export function fixtureEnvironment(
  directory: string,
  source: NodeJS.ProcessEnv,
): Record<string, string>;
export function prepareProtocolServer(
  directory: string,
  piConfig: { binaryPath?: string; enabled?: boolean },
  model?: string,
): Record<string, string>;
export function createServerGateway(options: {
  token: string;
  directory: string;
  piConfig: { binaryPath?: string; enabled?: boolean };
  accountRuntime?: ReturnType<typeof createAccountRuntime>;
}): Promise<{
  server: Server;
  serverURL: string;
  close(): Promise<void>;
}>;
