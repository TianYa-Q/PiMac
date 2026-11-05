// 固定 0.2.1 的公开工厂边界；不把第三方源文件纳入宿主适配器的类型检查。
// 上游发布的是原始 TS，内部 BeforeAgentStartEvent 类型尚未覆盖 Pi 的 custom 分支。
declare module "@schovest/pi-goal" {
  import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
  export default function goal(pi: ExtensionAPI, options?: { settingsPath?: string }): void;
}
