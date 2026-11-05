# T3 Code 逻辑复用边界与验收

## 用户方向与当前状态

保留 PiMac 原生 SwiftUI/AppKit 客户端，尽可能复用 T3 Code 的可靠逻辑以减少 bug。用户明确不希望使用 T3 Code 的 Electron 客户端；此前将“复用能力”解释为“必须完整迁移官方 Electron、Web UI 并退役 Swift 客户端”是误解，已撤回。

目前运行架构仍是 Swift 客户端与官方 Server 集成。引入完整上游源码只用于核对、提取和验证可复用逻辑，不代表已切换客户端，也不授权改变开发/打包默认入口。

## 复用边界

- 直接复用官方 Server、数据库迁移、认证与授权、Provider、运行时及其协议契约，不在 PiMac 新建平行的服务端业务实现。
- 对消息投递、命令身份、订阅、分页、重连、恢复、附件等客户端能力，先核实同版本官方实现与可解耦接口。能直接复用的逻辑直接复用；需要 Swift 适配的部分保持薄层，并通过真实上游契约验证。不能把“照抄思想”宣称为直接复用，也不预设尚未验证的跨语言运行桥。
- 原生 UI 和 macOS 集成继续保留。不强制使用 Electron、官方 Web UI 或将旧内核装入 Electron 壳。
- 不额外限制上游模型、Provider、工具、委派或原生能力；实际能力沿用发现、安装、授权及用户设置，不用空实现冒充支持。使用子代理仍需事先询问。
- 固定可复现上游版本，保留许可证与来源，避免客户端、Server、contracts 版本混搭。必要补丁说明目的及移除条件。

## 原生事件同步

- 使用官方 `orchestration.subscribeShell` 和 `orchestration.subscribeThread`；删除正文/列表的周期全量轮询。初次订阅或断线重连接收权威快照，后续按序应用增量，序号允许全局跳跃；不重放写命令。
- `sidecars/t3-client-state/index.ts` 只适配宿主：直接导入同一 pin 的官方 contracts、`orchestrationV2Projection.ts` 和 `shellReducer.ts`，在独立 actor 的 JavaScriptCore 中执行。不是 Electron，也不运行消息正文或工具生成的 JavaScript。
- 原生标签选择控制正文订阅；隐藏标签只消费 shell 状态，不清空历史。Telegram 的实际消费者持独立观察租约，避免隐藏桌面标签时丢回复；最后一个消费者退出后取消订阅和该线程的资源任务。
- 保留显式刷新、投递恢复、导出、统计等按需 HTTP 路径。资源不完整时独立分批续读，并遵守失败资源的重试时间，不依赖下一次正文事件；新正文、隐藏标签或前台投递会取消旧资源任务。首次选中和显式展示刷新使用官方 bounded snapshot，只读取近期窗口；顶部「加载更早消息」按官方不透明游标请求一页历史，直接复用 `threadHistoryMerge.ts` 合并，保留实时事件的新版本与序号。未加载旧页不进行资源水合；已加载窗口仍使用既有分批水合，并非逐行附件懒加载。隐藏或重连后的新订阅重新建立近期窗口；用户展开的旧页不写回启动缓存，缓存只保留最近 75 个展示条目。投递核对、导出等非展示用途仍保留完整权威读取。
- `third_party/t3code/` 保留普通上游源码快照，不保留内层 `.git` 或 submodule 注册；来源与 commit 记录在 `third_party/t3code-source.json`。这份源码目前是生成 reducer 的直接输入，不只是参考资料。
- 生成客户端资源：`GOMAXPROCS=1 node --import tsx scripts/build-t3-client-state.ts`。来源记录必须匹配 Server pin；升级时同步替换对应版本源码与来源记录。生成物和所打包依赖的许可证放在原生 Resources。原生构建不因此重新编译 Server。
- 校验生成物和 TypeScript 类型：同命令加 `--check`。针对性回归：`HistoryPagingTests`、`ConversationReadingPositionTests`、`T3StreamReducerTests`、`HTMLLiveHydrationTests`、`T3SubscriptionIntegrationTests`；后者在 `tmp/` 隔离真实 Server 验证零正文 GET、隐藏订阅取消、Unicode 增量、真实 WebSocket 断线恢复，以及超过首批八条工具详情后历史 HTML 无新事件仍能自动显示。

## 桌面会话引用

- 会话列表右键「复制会话引用」写入官方 `app.t3.context-fragment` UTI、纯文本和带 payload 的 HTML；Web MIME 不是合法 macOS UTI，跨 Web 通过官方 HTML fallback 读取。保留原有「复制 Thread ID」。
- `sidecars/t3-client-state/index.ts` 直接复用同一 pin 的 `composerContextClipboard.ts`、`composerContextReferences.ts` 和 contracts Schema。Swift 只适配 NSPasteboard、草稿/发件箱持久化、宿主分配粘贴身份及原生导航，不复制服务端的 Provider 上下文投影逻辑。
- 本入口导入 thread 引用，不承诺附件/终端/评审引用的创建或跨环境迁移；其他类型粘贴明确失败。已有消息的官方 records 整体保留，不因为原生 UI 不认识其类型而剥离 payload。发送时过滤已删除的引用，并拒绝跨环境 thread；未携带 payload 的链接不按标题或 ID 擅自补全。
- 引用随草稿、排队消息、发件箱原稿、取回/编辑和丢失会话迁移保存；投递命令仍按原身份冻结和恢复。异步粘贴遇到切换会话、取消或文字/选区变化，不向新草稿写入迟到结果。
- 原生正文中的会话链接及输入框上方引用可打开同环境会话；内容缺失或不可访问时明确提示。包含公式的正文也通过原生 `openURL` 路径处理引用，不交给系统浏览器。
- 回归：`ThreadContextTests`、`ThreadContextIntegrationTests`、`MessageRecoveryTests`、`ReplyAndDraftRegressionTests`。隔离 Server 测试覆盖官方剪贴板 → 原生适配 → 发件箱 → Server 投影 → Pi Provider，断言 Provider 收到 `threadId` 与读取指引，而非 `unavailable`。

## 输入恢复边界

- 旧输入待恢复不得单独阻止用户继续发送独立的新输入；恢复入口和原始错误仍保留。
- 新发送不扫描或自动重发旧输入。结果未知的旧输入只能按原消息/命令身份核对，禁止按正文去重或换身份自动重发。
- 真实进行中的投递仍串行保护；断线、配置未就绪、发件箱损坏或保存失败不得伪装成功。先持久化正文与附件再清空本次草稿，迟到响应不能清空后来编辑的内容。

## 验证与安全

1. 先确认同版本官方源码、契约、许可证及实际复用入口，再决定最小原生适配；不启动全面客户端迁移。
2. 使用项目 `tmp/` 下的隔离 Server 和确定性 fixture 验证，不首次运行就连接或迁移真实数据库，不抢占现有端口或进程所有权。
3. 验证发送、服务端接收后更新、断线重连、长会话、附件及失败恢复。单元测试、隔离 Server、真实原生视图和运行中应用的验收范围分别报告。
4. 保全现有会话、MessageOutbox 原稿、附件及未提交改动。不因恢复异常自动丢弃旧记录，也不以复用逻辑为由静默删除已有功能。
5. 真实数据迁移、应用停止/重启、发布继续遵守原授权与 reload/edit batch 屏障。代码完成、本地验证和实际发布分别报告。

诊断需关联请求、命令、消息及线程身份，并区分失败、未知结果、合法空状态和已接收。日志不得泄露认证凭据；可用性问题不能靠持续增加全量转录日志或无限重试掩盖。
