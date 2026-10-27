# T3 投递待恢复排查（2026-10-28）

状态：下述五项客户端缺陷已修复并完成本地回归；未发布、未强制重启运行中应用或 Server，未重放现场输入。最初超时的服务端内部原因尚未定位，不能把恢复缺陷修复当作该超时的完整根因。现场证据与缺陷描述保留修复前事实，修复与最终验证见末节。

## 结论

不是单纯的“线程数量没预留”，也没有发现当前桌面与打包 T3 的协议版本错配。客户端接入方式、恢复策略及状态机存在明确缺陷，会把正常准备阶段显示成待恢复，并把一次短暂超时放大为需人工处理、甚至执行期间无法处理的阻塞。

必须区分三层：

1. 触发因素：实际 HTTP 请求约 15 秒无响应而超时。
2. 放大因素：带附件时连只读预检失败也停止自动重试；恢复操作又受 agent 执行状态阻塞。
3. 其他独立缺陷：正常准备误报、missing 状态无法退出、并发确认后返回错误的投递结果。

## 现场证据

开始排查时，本机发件箱 78 条全部为 delivered。这只代表当时已交接，不证明从未发生过故障。

用户随后提供截图后再次读取元数据，出现 79 条 delivered、1 条 unknown。对应 unknown 记录：

- message ID：`F690D11A-B608-481C-B78D-AE6ADA5177FF`。
- 创建时间：2026-10-28 01:04:30.426 +08:00。
- 已有会话，1 个附件，环境身份已绑定。
- 错误为 `URLError.timedOut`，数值 `-1001`；不是权限拒绝。
- `dispatchCommand == nil`：正式 `message.dispatch` 还没有冻结，不存在本轮已发出该命令但丢回执的路径。不能据此扩大为“附件上传一定没有任何副作用”。
- 该会话仍在客户端缓存的权威列表里；这次没有发现 ThreadNotFound 拒绝记录。

同一窗口内，服务端 `server.getConfig` 于 01:04:31.027 接收、01:04:31.068 成功；认证与其他 RPC 继续成功，没有整体离线或权限失败证据。

macOS CFNetwork 的当前应用 PID 26697 记录了多次约 15–16 秒超时，均已写出请求、尚未收到响应字节。01:04:34.728 发起的 task 5669 于 01:04:49.860 超时，耗时 15132 ms、response bytes 为 0；随后同类 992-byte 请求于 01:04:52.951 成功，耗时 2557 ms。该连接此前还成功处理了 websocket-ticket HTTP 请求。

这些记录更支持共享普通 HTTP 通道中的列表读取出现间歇性停顿，而不是单纯等待空闲连接：请求已发送，认证检查仍成功。但系统隐私遮蔽了 URL，本地连接诊断也不记录 shell/thread 路由，**不能仅凭请求字节数和连接复用，把 task 5669 确认为该输入的某个具体阶段**。

当前缓存有 839 条活跃区会话记录、3 个项目，缓存 JSON 约 1.9 MB。这是后续性能复现应使用的规模，不等于已经证明慢 SQL 或历史规模就是超时根因。

## 已确认的客户端缺陷（修复前）

### 1. 附件使安全只读预检也失去自动重试

`MessageOutbox.swift` 的 `deliver` 使用以下条件控制重试：

```swift
record?.attachments.isEmpty == true || record?.dispatchCommand != nil
```

它不区分失败发生在环境/快照/项目读取、附件上传，还是消息提交阶段。带附件且命令尚未冻结时，即使失败发生在完全无变更副作用的只读检查，也只尝试一次。

探针向真实 coordinator 的 snapshot 边界注入 timeout，结果为 snapshot 读取 1 次、上传 0 次、提交 0 次；即使提供三个重试延迟，也直接留下 unknown。此处验证的是客户端状态机，不声称模拟了现场 Server 卡顿。

修复方向：记录明确的投递步骤和上传是否已发出；只读检查可有限重试，未核验的上传仍保守处理，冻结命令继续沿用原 command ID。

### 2. agent 正在运行时，恢复入口被一起禁用

`AppModel.isBusy` 包含 `isStreaming`。`MessageRecoveryBar` 主按钮使用 `.disabled(app.isCheckingDelivery || app.isBusy)`；`continueDeliveryRecovery` 又要求 `!isBusy`。

正常发送允许 agent 运行期间排队/steer，但一旦这次输入出错，恢复却要等 agent 空闲。截图中“Server 已连接、任务仍运行、恢复按钮变灰”可由该门禁直接解释。此处不是线程锁没有释放。

修复方向：把只读核验、投递互斥、agent 执行三个门禁分开；迁移和可能重复执行的操作继续保留独立保护。

### 3. 正常发送准备期也会显示待恢复

`OutboxMessage.State.saved.needsRecovery == true`。`deliverAttempt` 完成 `inspect` 后才改为 sending，而 inspect 包括 config RPC、会话快照与项目列表刷新。

因此正常网络等待期间，记录仍为 saved，气泡标题和恢复栏已经显示待恢复；不需要任何错误即可出现。独立探针已复现 activeThreads 持锁、未发送命令、无错误时仍出现“你 · 待恢复”。

修复方向：运行中的准备状态与需要用户介入的状态分离，同时保留崩溃后 saved 输入可找回的能力。

### 4. missing 会话恢复可读后，状态无法退出

一次 404 将记录设为 missing。后续快照重新可读且未查到对应消息时，inspect 返回 ready，但没有清除 missing；deliverAttempt 又明确拒绝 missing，于是出现“检查可以继续、实际继续永远失败”。

隔离状态机探针已复现。它是恢复算法缺陷，尚无证据证明截图这条输入经过了此分支。

修复方向：重新核验环境、项目、线程身份后，按事实更新状态；禁止以单次列表缺失直接重建同 ID 会话。

### 5. 权威快照确认与预检竞态会返回错误结果

预检读取快照后、刷新项目期间，如果其他观察者通过 `store.acknowledge` 把该消息置为 delivered，inspect 仍可能基于先前记录返回 ready。deliverAttempt 随后因为记录不可见返回 false，尽管消息已经正确交接。

探针已复现 delivered、无重复命令、返回 false。此缺陷会误报提交结果，不代表实际消息丢失。

修复方向：在每个 await 后读取当前事实；accepted/delivered 必须优先作为成功结果收敛。

## 接入方式中的放大因素及诊断缺口

- 桌面每次投递先做 config RPC、完整线程快照和 shell 刷新，轻量发送依赖了多项较重的读取。`recoveryProjectID` 还会等待共享 `refreshShell`，所以后台列表变慢可以影响投递。
- 桌面依赖 500 ms（有运行任务）/2000 ms（空闲）全量列表轮询，而不是官方 afterSequence 增量订阅。不能仅把轮询改成订阅就宣称根治，但当前规模需要复现与量化。
- 已有 4/4/4 的普通 HTTP、线程、资源独立池，以及独立健康检查池；并非完全没有隔离。投递预检仍使用列表共享任务和连接池，隔离没有覆盖整条关键路径。
- 健康检查成功只证明 `/api/auth/session` 可达，不证明列表、会话读取、附件或提交均健康。绿色徽标与某次投递超时并不矛盾。
- 连接诊断不记录 `/api/orchestration/shell` 和线程读取阶段；outbox 只留总错误，没有失败步骤与耗时，RPC 日志也没有按投递阶段关联。当前证据无法在会话读取、项目列表读取和上传请求进入处理器前停顿之间作最终区分。
- 未发现能证明本次由数据库锁、Node 事件循环停顿、HTTP 连接复用缺陷或模型上下文不足触发的证据；没有访问生产 SQLite，也没有用猜测替代它。

要完成“首次超时为什么发生”的根因闭环，下一步必须补充无正文/无凭据的阶段化耗时与 request metrics，并在隔离 Server 中复现接近 839 条会话、并发运行和图片投递的场景。必要时再对明确范围的真实环境诊断申请授权，不能盲目扩大到生产数据库。

## 版本及契约验证

- 固定上游：`81493efb71e8e8244f95d3e9f71d8369654ab151`，协议 2。
- 当前运行 app 中的 t3-server.mjs 与工作区 vendor 文件 SHA-256 相同。
- `npm --prefix sidecars/t3-server run check` 在 `umask 022` 下通过：126 个原生依赖包、2078 个固定源码文件、7,890,855-byte bundle。
- 第一次在工具环境 `umask 077` 下报告 native runtime stale；已核对清单内 9717 个文件 hash/mode 全部匹配。归因于临时补丁产物权限差异，统一 umask 后校验通过，不是已运行 Server 源码过期；未因此重新生成或替换运行资源。
- 对照官方 HTTP 404 契约、环境身份与项目身份、thread.create/message.dispatch 原 command ID 回执语义，没有发现这次是协议字段不兼容。

## 排查阶段验证与边界（修复前）

1. `swift test --jobs 1 --no-parallel --filter 'MessageRecovery|T3ConnectionRecovery|T3DesktopTests|ThreadRefreshScheduler'`：33 项通过，含隔离真实 Server 的丢回执、重启、原 ID 去重及缺失会话迁移。
2. 本次 5 个独立探针全部复现上述客户端行为。探针是当前缺陷的观察断言，不是“问题已修复”的绿灯，也不能用其替代服务端业务验收。
3. 临时探针位于 `tmp/t3-recovery-audit/T3RecoveryAuditTests.swift`；运行期间的测试入口软链接已移入废纸篓，未留在正式 Tests。相关日志也在该临时目录。
4. 没有 UI 实现修改，因此没有用隔离组件图冒充运行中界面修复验收；现场 UI 证据为用户提供的截图。
5. 未修改用户发件箱、未发起真实模型任务、未取消已有任务、未修改生产数据、未发布或重启。

## 修复结果与最终验证

- `MessageOutbox.swift` 按环境、会话快照、项目、项目创建、会话创建、附件准备、上传、提交区分阶段。只读预检短暂失败不再因带附件而放弃有限重试；上传结果未知仍停止自动重试；冻结命令始终保持原 ID 和正文。
- 在首次异步预检前转为 `sending`，正常准备不再显示“待恢复”；崩溃后仍转为 `unknown`。AppModel 在提交开始时不把刚保存的记录当作待人工恢复，未主动提交的历史 `saved` 记录仍可找回。
- `AppModel` 与恢复栏将只读核对、投递互斥、Agent 执行门禁分开。执行期间可核对、按原身份继续排队/steer；压缩、模型设置、账号管理和交互请求仍阻止变更，迁移/停止恢复等原保护不放宽。
- 原线程重新可读且环境、线程、项目身份全部一致时允许退出 `missing`；详情提供重新核对。项目读取自身的 404 不再误判为线程丢失，也不会直接重建原 ID。
- 预检、项目创建、附件准备/上传及退避期间重新核验当前状态；权威确认优先收敛为成功，迟到错误或取消不把已确认投递误报为失败。
- 发件箱新增可选 `lastFailure`：安全阶段、该阶段耗时（毫秒）、发生时间、受控错误原因；旧记录可继续读取，详情展示阶段及耗时，不记录原始 URL、鉴权信息或响应正文。这能定位后续失败阶段，但不是完整 HTTP request metrics，也不证明最初停顿的内部原因。

最终验证：

1. `swift format lint --strict`：本次修改的 5 个 Swift 文件通过；Swift 编译/类型检查随测试通过。已有 `LidSleepController.swift` 非 Sendable 默认函数警告不属于本次改动。
2. `swift test --jobs 1 --no-parallel --filter 'MessageRecovery|T3ConnectionRecovery|T3DesktopTests|ThreadRefreshScheduler'`：40 项、4 个套件通过，日志 `tmp/t3-recovery-fix/final-tests.log`。包括阶段重试、上传不确定性、预检中断重载、运行中恢复、跨环境阻断、missing 复归、项目读取 404、权威确认竞态、退避取消、诊断脱敏。
3. 隔离真实官方 T3 Server + fixture Pi Provider：携图预检超时后重试、图片实际上传一次、丢失提交回执后原 ID 重放、Provider 仅执行一次、客户端/Server 重启及迁移路径通过。不是生产 Provider/生产会话验收。
4. 真实原生 `MessageRecoveryBar`，相同 fixture、760×200、深色，挂起检查/完成检查三个阶段捕获通过：`tmp/t3-recovery-fix/before.png` 与 `after-final.png`，对比 `comparison-final.png`。运行任务时按钮由错误禁用变为可用，核对中仍禁用，核对后允许继续发送。主操作槽保持宽度；标题、详情按钮、状态图标区域在三阶段像素一致，结果 `visual-stability.json`。这是隔离组件截图，不是运行中 App 的全页验收。
5. 未修改现场发件箱或原输入，未自动扫描/重放历史积压，未执行生产发布或强制重载。安全释放本任务 edit batch 后仍由既有 watcher 的空闲与未确认输入屏障决定是否重载。
