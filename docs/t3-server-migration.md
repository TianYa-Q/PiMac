# 官方 T3 Server / Pi 迁移

## 固定版本与所有权

当前使用 `pingdotgg/t3code` 官方 main 提交 **`442735897f6f92af33798075baa12d4fd4d710dd`**（2026-10-06 UTC），使用 orchestrator V2、官方 Pi Provider 和 Effect/platform **4.0.1**。本轮升级目标为 T3 iOS **build 109**；手机构建号由 EAS 远程管理，不等于 Server 版本，尚未验证其与上游提交的精确对应及实机兼容性。新增放行官方 `orchestration.getTurnItem`，用于手机按需读取工具详情，保留官方只读权限和线程隔离。

```text
SwiftUI / Telegram / T3 iOS（需要支持 orchestration protocol 2）
                        ↓ 官方 HTTP / Effect RPC
T3 Server：orchestrator V2、SQLite、原生回执、投影、运行队列
                        ↓ 官方 PiDriver / PiAdapterV2 / PiRpc
Pi runtime：原生认证、模型、扩展、skills、上下文和 session 文件
```

- 已删除自研 `pi-provider.mjs`、`pi-rpc.mjs` 及私有 session-control、extension-response、metrics、account-status 通道。不再自行持有或复刻 Pi runtime。
- 桌面写入走官方 `projects.mutate` 和 `orchestration.dispatchCommand`。消息、模型、取消、扩展回答分别使用 `message.dispatch`、`thread.model-selection.set`、`run.interrupt` 和 `runtime-request.respond`。
- HTTP 快照读取必须带 `x-t3-orchestration-protocol: 2`；WebSocket 必须带 `orchestrationProtocol=2`。旧客户端不兼容，不绕过服务端版本检查。
- `T3V2Presentation.swift` 只将官方 V2 快照映射为既有 SwiftUI 展示结构，不写入第二套投影或回执。桌面仍轮询快照（运行中 250ms，空闲 1000ms）；手机使用官方订阅。
- `native.mjs` / `management.mjs` 仅提供 Mac 宿主访问策略、桌面凭据和 T3 Connect 管理。上游源码通过 SHA-256 manifest 固定，构建补丁仅保留宿主所需的 loopback/auth/Connect 和未打包其他 provider/native dependency 的策略；PiDriver、PiAdapterV2、PiRpc 本身不打补丁。

## 已接入

- 原生 T3 Git/VCS RPC 与进度订阅，保留上游权限校验。桌面 Git 面板支持分支/变更/差异、选定文件提交、推送、创建 PR 与拉取；按当前线程 worktree 定位，不自行绑定 worktree。操作确认、未确认结果不重放及多项目差异预览的真实路径边界见 [Git 集成说明](t3-code-integration.md#git--vcs)。
- 官方模型发现及 `thinking` 选项（包括模型支持的 xhigh/max）；切换模型和思考等级。
- 发消息、插入消息、取消、`agent_settled` 终结、原生回执去重和重启恢复。
- 先通过官方 `assets.persistChatAttachments` 存储图片，再发送附件；图片读取使用官方签名 URL。
- 官方 `runtimeRequests` 中的单问题 select/input/editor 和 confirm/工具审批通过桌面对话框回答。editor 遵循上游的文本问题表示，不保留旧私有 prefill 协议。
- 手动压缩走官方 `/compact` 消息，不直接调用私有 Pi RPC。
- 上下文与 token 指标来自官方 `providerTurns.tokenUsage`。当前上游 Pi 未提供 per-turn usage/费用字段，因此速度和费用保持不可用；不把累计输出除以单 turn 时长，也不显示虚构的 $0。

## 状态、升级与安全

- 继续使用 `server-owned/` 和已有环境身份。SQLite schema 与旧 T3 V1 历史导入由上游负责；桌面不扫描或重写 JSONL。原始旧 `pi-sessions/` 文件不删除。
- 自研 Adapter 的 continuation cursor 不是官方 Pi native session 文件路径，**不能承诺旧自研线程原样续接同一 Pi runtime**。上游 V1 历史恢复/portable-context handoff 与原生新线程续接是不同路径；既有真实历史升级仍需单独验收。
- 首次遇到旧 `binaryArgs` 配置，先保存准确的 `settings.json.before-official-pi`，再转换为官方 `launchArgs`。只剔除旧宿主注入的 pimac-fast/pimac-compaction 扩展，保留用户扩展参数和其他设置。新线程使用官方 Pi 原生 session 存储。
- 不再自动注入 Fast/压缩模型扩展。用户自己安装的 Pi 扩展继续由 Pi 加载，自动压缩和压缩模型遵循 Pi 配置。
- 所有监听保持 loopback；远程仅通过官方授权的托管 Cloudflare Tunnel。运行 Pi 前清除宿主管理环境凭据，Pi 子进程不继承 `PIMAC_T3_*` token。
- 未确认提交不自动重发，不自动重启正在运行的应用。首次启动新构建前，先等待任务结束，并备份真实 Server 状态目录；SQLite 升级后不要直接用旧构建打开升级后的数据库。

## 明确的功能差异

- 官方 V2 的 wire projection 会移除任意工具输出、完整 diff 和工具生成图片；当前桌面保留工具名称/输入/状态，不恢复旧私有富输出链路。
- codemode 的嵌套调用按上游提供的独立工具项展示，不再自研聚合 runtime 事件。
- Pi 的 setStatus/title/widget 等终端装饰上游忽略。账户额度现在由独立的本机只读管理模块查询，不依赖 runtime status：支持 openai/openai-codex 的原生 OAuth 和 account-usage 多账户存储，按 Provider 隔离，缓存一分钟，手动刷新绕过缓存。读取仅接受当前用户的私有普通文件，返回字段白名单，不返回凭据、不写 auth/session、不触发付费 warm-up。过期授权明确报错，刷新授权仍由 Pi/扩展负责。Gemini 额度、reset credits 和线程授权绑定尚未补齐。
- 原生 auth 与多账户列表按稳定 ChatGPT account ID（含 token 内的身份信息）合并，不因 token 刷新重复显示。匹配后保留用户账户名称，只为本次查询选用更新的授权，不改写存储；未匹配项标为“Pi 已保存授权”，不标为默认或当前线程账户。Telegram 未确认线程绑定时明确显示“未确认”，只读列表不提供切换按钮。
- 桌面“管理”通过官方 message.dispatch 提交 `/accounts`，需要已安装 account-usage 扩展；命令提交不等于管理已打开。桌面直接账户切换保持禁用，不能把全局授权误认为某个线程的当前账户。额度接口只在独立 supervisor socket 上开放，需要宿主管理凭据，拒绝浏览器 Origin，不开放到 Tunnel。
- 模型隐藏是服务端共享的选择器展示规则：桌面保存后，官方 `server.getConfig`、`server.refreshProviders` 和 `subscribeServerConfig` 的 Pi 模型列表均按隐藏 slug 过滤，已连接手机收到实时目录更新，规则重启后保留。所有 Pi 实例应用同一组隐藏 slug；非 Pi provider 不受影响。底层 provider catalog、桌面管理用完整目录、线程模型选择与运行不被过滤，历史线程仍可使用隐藏模型。手机自身收藏/展示偏好仍由手机管理。
- 独立压缩模型选择、旧 Fast 选项不再由桌面覆盖 Pi。
- 真实模型/账号、旧真实数据升级、App Store iOS protocol 2、Apple 登录和 APNs 尚需实机验收。

## 验证

```sh
./scripts/prepare-t3-server.sh
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
swift test
```

Server 测试使用真实打包官方 Server 和协议 Pi fixture，不访问账号或模型，覆盖模型发现、protocol 1 拒绝、V2 回执、session 文件续接、steering/取消、扩展回答、/compact、附件签名访问、Connect/TLS/DPoP 及配置迁移。fixture 测试不替代真实数据和手机验收。
