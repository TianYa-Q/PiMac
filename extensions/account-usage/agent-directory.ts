import { homedir } from "node:os";
import { join } from "node:path";

/** 宿主与会话共用同一存储位置，不为读取账户文件加载整个 Pi 会话运行时。 */
export function getAgentDirectory(): string {
  const directory = process.env.PI_CODING_AGENT_DIR;
  if (!directory) return join(homedir(), ".pi", "agent");
  return directory === "~"
    ? homedir()
    : directory.startsWith("~/")
      ? join(homedir(), directory.slice(2))
      : directory;
}
