# 官方 T3 Server / Pi 迁移

## 固定版本与所有权

当前使用 `pingdotgg/t3code` 官方 main 提交 **`26fffe5aee22ea9bdd39c5b4c400f643c560b4a0`**（2026-10-15 UTC），使用 orchestrator V2 和 Effect/platform **4.0.4**。Provider 已按上游拆分为 workspace packages。Server 提交不是 iOS 构建号；手机实机兼容性仍需单独验收。工具详情沿用官方 `orchestration.getTurnItem` 及上游权限、线程隔离。

本软件面向单用户，PiMac 主要提供习惯的 UI 和宿主集成，不额外限制官方 Server 的 Provider、模型、委派或工具能力。已移除父模型锁及 Pi-only/native-disabled 权限策略；认证与权限模式仍由官方 T3 决定。用户的“只检查 Pi”单独实现为可更改的发现偏好，不是 Provider 白名单。

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
- `native.mjs` / `management.mjs` 提供 Mac 宿主集成、桌面凭据和 T3 Connect 管理，不添加第二套权限系统。上游源码和原生依赖补丁通过 SHA-256 manifest 固定。Pi adapter 只保留展示所需的逐轮遥测、账户状态与 Fast 集成；图片输出及历史读取沿用上游实现。其他官方 Provider 与原生能力完整随应用打包，不因桌面暂未展示而移除或限制权限。

## 已接入

- 原生 T3 Git/VCS RPC 与进度订阅，保留上游权限校验。桌面 Git 面板支持分支/变更/差异、选定文件提交、推送、创建 PR 与拉取；按当前线程 worktree 定位，不自行绑定 worktree。操作确认、未确认结果不重放及多项目差异预览的真实路径边界见 [Git 集成说明](t3-code-integration.md#git--vcs)。
- 官方模型发现及 `thinking` 选项（包括模型支持的 xhigh/max）；切换模型和思考等级。
- 发消息、插入消息、取消、`agent_settled` 终结、原生回执去重和重启恢复。
- 先通过官方 `assets.persistChatAttachments` 存储图片，再发送附件；图片读取使用官方签名 URL。
- 官方 `runtimeRequests` 中的单问题 select/input/editor 和 confirm/工具审批通过桌面对话框回答。editor 遵循上游的文本问题表示，不保留旧私有 prefill 协议。
- 手动压缩走官方 `/compact` 消息，不直接调用私有 Pi RPC。
- 上下文与 token 指标来自官方投影，Pi 遥测补充逐条模型回复用量和 AA 近似输出速度。缺少有效用量或流式样本时不虚构速度或费用，不把累计输出除以单 turn 时长。

## 状态、升级与安全

- 继续使用 `server-owned/` 和已有环境身份。SQLite schema 与旧 T3 V1 历史导入由上游负责；桌面不扫描或重写 JSONL。原始旧 `pi-sessions/` 文件不删除。
- 自研 Adapter 的 continuation cursor 不是官方 Pi native session 文件路径，**不能承诺旧自研线程原样续接同一 Pi runtime**。上游 V1 历史恢复/portable-context handoff 与原生新线程续接是不同路径；既有真实历史升级仍需单独验收。
- Provider 发现默认仅启用 Pi：为其他官方默认槽显式写入 `enabled: false`，避免上游缺省槽自动启用 Codex/Claude。现有设置只迁移一次，准确备份为 `settings.json.before-pi-discovery-v1`，写入成功后创建 `settings.json.pi-discovery-v1` 标记；关闭非 Pi 实例及项目启用覆盖，但保留原配置、环境、模型选择及所有无关设置。之后通过官方 `server.updateSettings` 启用其他实例会恢复检查与状态行，重启不重置。禁用状态行仅在客户端目录快照/订阅隐藏；底层注册表、原生依赖、运行路由、安装/管理 API 与官方 scope 不裁剪。独立安装服务改为惰性初始化，后台安装订阅及历史/账户用量发现服从官方实例/项目启用状态，默认不探测 Codex/Claude 的安装、版本或用量。Pi 模型使用的 OpenAI/Codex/Claude 等服务不受此偏好限制。
- 首次遇到旧 `binaryArgs` 配置，先保存准确的 `settings.json.before-official-pi`，再转换为官方 `launchArgs`。只剔除旧宿主注入的 pimac-fast/pimac-compaction 扩展，保留用户扩展参数和其他设置。新线程使用官方 Pi 原生 session 存储。
- Fast 选项通过官方加载的 MCP 扩展接入；不替换 Pi 的运行生命周期或压缩实现。用户扩展、自动压缩与压缩模型仍遵循 Pi 配置。
- Server 和 supervisor 管理保持 loopback；远程通过独立 LAN 代理或官方授权的托管 Cloudflare Tunnel。运行 Provider 前清除宿主管理环境凭据，子进程不继承 `PIMAC_T3_*` token。
- 未确认提交不自动重发，不自动重启正在运行的应用。首次启动新构建前，先等待任务结束，并备份真实 Server 状态目录；SQLite 升级后不要直接用旧构建打开升级后的数据库。

## 明确的功能差异

- 官方 V2 的 wire projection 仍移除任意工具输出、完整 diff 和图片字节。桌面对已完成 dynamic_tool 使用官方 `orchestration.getTurnItem` 发现图片元数据，再通过 `assets.createUrl` 的 `tool-output-image` 签名资源下载；生成图片作为独立回复附件展示，不受工具组折叠影响。没有恢复旧私有富输出链路。
- 回复中的显式 Markdown 本地图片链接通过官方 `media-file` 资源解析（相对路径遵循线程 workspace/worktree），自动显示缩略图，点击链接或缩略图均可预览。支持 PNG/JPEG/WebP/GIF，最多每条 8 张、每张 20 MB；验证 MIME 与图片尺寸，不自动抓取远程 URL、代码示例或 SVG。失败有限重试，重新打开线程可再次尝试。
- codemode 的嵌套调用按上游提供的独立工具项展示，不再自研聚合 runtime 事件。
- Pi 的 setStatus/title/widget 等终端装饰上游忽略。账户额度现在由独立的本机只读管理模块查询，不依赖 runtime status：支持 openai/openai-codex 的原生 OAuth 和 account-usage 多账户存储，按 Provider 隔离，缓存一分钟，手动刷新绕过缓存。读取仅接受当前用户的私有普通文件，返回字段白名单，不返回凭据、不写 auth/session、不触发付费 warm-up。过期授权明确报错，刷新授权仍由 Pi/扩展负责。Gemini 额度、reset credits 和线程授权绑定尚未补齐。
- 原生 auth 与多账户列表按稳定 ChatGPT account ID（含 token 内的身份信息）合并，不因 token 刷新重复显示。匹配后保留用户账户名称，只为本次查询选用更新的授权，不改写存储；未匹配项标为“Pi 已保存授权”，不标为默认或当前线程账户。Telegram 未确认线程绑定时明确显示“未确认”，只读列表不提供切换按钮。
- 桌面“管理”通过官方 message.dispatch 提交 `/accounts`，需要已安装 account-usage 扩展；命令提交不等于管理已打开。桌面直接账户切换保持禁用，不能把全局授权误认为某个线程的当前账户。额度接口只在独立 supervisor socket 上开放，需要宿主管理凭据，拒绝浏览器 Origin，不开放到 Tunnel。
- 模型隐藏是服务端共享的选择器展示规则：桌面保存后，官方 `server.getConfig`、`server.refreshProviders` 和 `subscribeServerConfig` 的 Pi 模型列表均按隐藏 slug 过滤，已连接手机收到实时目录更新，规则重启后保留。所有 Pi 实例应用同一组隐藏 slug；非 Pi provider 的模型不受此规则影响，已禁用实例的状态行另按发现偏好隐藏。底层 provider catalog、桌面管理用完整目录、线程模型选择与运行不被过滤，历史线程仍可使用隐藏模型。手机自身收藏/展示偏好仍由手机管理。
- 独立压缩模型选择不由桌面覆盖 Pi；Fast 沿用受支持 Provider 的实际能力，不伪造成功。
- 真实模型/账号、旧真实数据升级、App Store iOS protocol 2、Apple 登录和 APNs 尚需实机验收。

## 验证

```sh
./scripts/prepare-t3-server.sh
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
swift test
```

Server 测试使用真实打包官方 Server 和协议 Pi fixture，不访问账号或模型，覆盖模型发现、protocol 1 拒绝、V2 回执、session 文件续接、steering/取消、扩展回答、/compact、附件签名访问、Connect/TLS/DPoP 及配置迁移。fixture 测试不替代真实数据和手机验收。
