# PiMac 内部模块管理

PiMac 的 Pi 核心、Antigravity、Web Access、Goal、账户模块与 Goal 展示适配器统一由仓库管理。
设置页只显示当前/最新版本及查询失败原因，没有安装、卸载、单项更新或全部更新入口。
固定版本仍查询 npm 最新版，不再把“已固定”当作不展示最新版本的理由。

## 当前固定版本

- `@earendil-works/pi-coding-agent` / `pi-ai` / `pi-tui`: `1.5.0`
- `pi-antigravity`: `0.11.0`
- `pi-web-access`: `0.47.0`
- `@schovest/pi-goal`: `0.2.1`
- 自有账户/展示模块：读取自身 package.json；无独立 Registry 发布，最新表示当前内部维护版本。

版本来自实施时 npm 的 latest 元数据，不代表未来永远最新。升级由开发流程修改精确依赖并更新 lockfile，
经过验证再部署；设置页不会替用户写依赖或更新配置。

## 部署与检查

源码部署（Node 24+）：

```sh
npm ci --ignore-scripts --legacy-peer-deps --prefix extensions/runtime
node --import ./extensions/runtime/node_modules/tsx/dist/loader.mjs scripts/manage-pi-runtime.ts
node --import ./extensions/runtime/node_modules/tsx/dist/loader.mjs scripts/manage-pi-runtime.ts --check
```

脚本按 lockfile 安装内部 runtime、Goal 适配器、账户模块，链接账户扩展，适配 Pi 1.5 的已有无限重试策略，
并使用官方 FileSettingsStorage 的锁合并用户配置。只接管已知模块，保留其他包、认证、模型、项目及账户数据。
不重装用户全局 Pi，不覆盖运行中的外部 Pi 文件，不重启 Server/客户端。

`extensions/runtime/package.json` 和 package-lock.json 是核心/第三方模块的唯一版本选择入口。
安装 receipt 位于 `~/Library/Application Support/PiMac/ManagedRuntime/modules.json`，记录实际运行入口和模块文件位置。
原生端每次核对实际 package.json 版本与 receipt；缺文件/损坏/版本不一致明确报错，不回退成“零模块”或成功。
生产 Server 仅使用该核实后的内部 Pi；测试的隔离 stateDirectory 仍允许注入 fixture 二进制。

这是当前源码部署方式，receipt 的绝对路径属于本机部署，不是已发布安装器或可移植应用打包的宣称。
移动 checkout 后必须重新运行部署脚本。当前发布 ZIP 不因此自动包含新版运行时；发布需独立完成部署/打包与安全验收。
正在工作的会话保留其已经加载的版本；仅在正常安全重载后使用新核心和模块，不为升级强停任务。

## 兼容性验证

- 真实 Pi 1.5 RPC 同时加载 Antigravity（含搜索和图片工具）、Web Access、Goal、账户模块，
  断言关键工具注册、单个 `/goal` 命令，并执行确定性离线 Provider 请求，无 extension_error。
- 真实 Pi 1.5 的 SDK/CLI 无限重试验证：超过三次失败后恢复、不重复工具副作用、永久错误不重试、
  Goal 重试中保持 active、退避停止后不自动复活。新 Goal 对失败后的 abort 可能标为 blocked，保留此原生行为。
- Goal RPC 恢复/暂停/编辑/无确认清除；账户模块新版类型检查与 126 项测试。
- Swift 的真实文件 inventory 检查、版本展示、父子停止及原生 Server fixture。
- 设置页使用同条件真实 SwiftUI/AppKit 合成窗口截图；不是生产运行中应用截图。

不把工具注册/离线协议测试冒充真实 OAuth 登录、远端生成、实际模型自动续跑或手机实机验收。

## Git

所有深度的 node_modules、npm/pnpm 本地缓存、Swift 构建、tmp 和生成运行产物均忽略。
模块源码、package.json、package-lock.json、正式测试和内部部署脚本必须保留在版本控制中。
