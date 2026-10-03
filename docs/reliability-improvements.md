# PiMac / account-usage 稳定性与体验优化

## 本轮：并发额度查询与 Git 差异体验

- 额度缓存改为双层锁：provider namespace 的 SHA-256 锁负责合并同源查询；全局文档锁仅用于短暂读取和写入。Gemini、Codex、OpenAI 可并发查询，慢接口不再占住其他 provider 的网络刷新。
- 查询结束后重新读取最新文档再合并，避免并发 provider 互相覆盖。保持原缓存格式、权限、取消、强制刷新和失败不覆盖语义；旧扩展进程仍兼容，但其原有长时间全局锁会影响并发收益。重启旧会话以获得完整优化。
- Git 文件面板新增“仅看未选”，支持默认顺序、文件路径自然排序和变更量排序。排序不改变提交范围，极端计数仍使用饱和加法。
- 差异请求状态从 SwiftUI 抽离为可测试 store，过期成功、过期错误均不能覆盖较新结果。严格校验 consumed 字段，异常响应不再被误判为“没有差异”。
- 本机差异预览限制为 2 MiB，安全截断 UTF-8，并显示截断提示；新增“复制差异”，只复制当前预览，不发起额外请求、不修改文件。
- 纳入已有 Tunnel watchdog：持续全边缘离线时有限重启 connector，不重启 Server 或 Pi 任务，不更换 Tunnel 身份。详见 [T3 连接说明](t3-code-integration.md)。

验证：`./scripts/check.sh` 通过（Swift 214 项、account-usage 47 项、PiCompatibility 5 项、Server 80 项，包含 Fast 与真实 Pi RPC/codemode sandbox 检查）；DevWatcher 20 项通过；Git 原生集成复测通过。修复一处既有 Swift 测试格式问题，不改变行为。

新增回归覆盖跨 provider 并发与合并、锁等待取消、预览乱序及取消、非法响应、UTF-8 截断、文件排序与溢出。真实窗口布局、手机重连及真实 OAuth/额度接口仍需人工验收；本轮不会发布、推送、修改真实账户或重启正在工作的应用。

## 定时任务

- 搜索覆盖标题、提示词、项目名、模型与最近错误；空白分隔的多个关键词必须同时匹配。
- 筛选全部、启用、暂停、派发失败，并显示匹配数量和最近成功刷新时间。
- “复制”仅生成编辑草稿，保存前不会请求 Server。新 ID、新 command ID、默认暂停、每次新建会话、root 工作区；保留提示词、周期、provider/model 和权限模式，不复制原模型选项、worktree 或运行记录。保存后需要用户明确启用。
- 校验错误可以直接修改后重新保存，不必先刷新。传输中断导致的未知操作结果仍阻止所有修改，必须手动成功刷新；不会重试潜在已生效的操作。
- 失败或取消的刷新保留已知列表。重复／空任务 ID 被拒绝，避免 SwiftUI 身份冲突。只有成功取得并解析列表才更新刷新时间。
- 搜索与筛选抽离为纯展示逻辑；刷新阻断状态与错误文案独立，避免用字符串存在与否决定操作安全性。

## Pi extension 与宿主 UI

- account-usage 的 usage / reset-credit JSON 按块读取，限制实际接收量为 64 KiB。伪造或缺失 Content-Length 不能绕过限制；超限即取消剩余数据。分片 UTF-8 正确重组后解析。
- 用户取消会解除等待中的 reader；HTTP 错误响应体不再遗留，15 秒请求超时不再误标为用户取消。辅助 reset-credit 失败仍不隐藏有效 usage。
- 普通扩展状态按 AppModel 来源隔离，切换会话仅展示该来源的状态；关闭来源会清理状态。不改变 provider 共享额度快照的兼容策略。
- JSONL 解码器保持增量线性扫描，默认最多保留 16 MiB 的单条记录。超限记录一直丢弃到下一 LF，再恢复解析，不把残片当作新记录；可通过 `droppedRecordCount` 查看丢弃数。该限制作用于宿主 Server stdout reader，不改变 Pi 会话文件或 Server 的 RPC 数据。
- Server stdout EOF 会提交最后一条无换行尾记录。旧 Fast 扩展仅用于兼容测试，明确从 Swift target 排除，消除未声明资源警告。

## Git 状态边界与提交范围（本轮）

- Git 刷新在替换快照前严格校验仓库标记、分支、非负整数计数、文件路径及 refs。缺字段、重复文件身份、布尔值冒充计数等响应不会解锁写操作；保留最近有效快照并要求重新刷新。
- 最近成功刷新时间独立于 loading/error，刷新失败不更新；切换工作区清空旧时间。
- 文件范围支持“全部文件 / 仅看已选”，与多关键词搜索组合。筛选不修改选择；增加清空选择及所选文件增删行统计。统计使用饱和加法，避免极端计数导致宿主崩溃。
- 筛选与统计均集中在纯展示层，Git 操作仍由官方 Server 执行，不新增自动重试。

## 共享额度缓存边界（本轮）

- Codex / OpenAI 缓存值必须逐项符合账户额度结构，且精确匹配此次请求的账户集合；错误账户、重复账户、非法百分比或 reset-credit 结构均作为 cache miss，重新查询。
- Gemini 磁盘快照复用实时接口解析器，不再仅凭缓存版本信任内部结构。
- 查询结果同样经过校验；无效结果不覆盖旧缓存，锁仍正常释放。
- 账户集合 key 使用 JSON 编码，避免分隔符造成的集合歧义；旧 key 自然失效，不迁移真实账户。
- 磁盘缓存读写最多 1 MiB，读取限额不依赖单次 stat，超大缓存按 miss 恢复；超大写入保留旧文件。
- HTTP JSON 使用严格 UTF-8 解码，非法字节不再静默替换成字符；现有分片 UTF-8、限额及取消语义不变。

本轮验证：`./scripts/check.sh` 全部通过，Swift 209 项、account-usage 45 项、PiCompatibility 5 项、Server 80 项；Fast 与真实 Pi RPC/codemode sandbox 检查通过。DevWatcher 20 项通过。新增 UI 尚未进行真实窗口人工验收。

## 验证与边界

运行 `./scripts/check.sh`：Swift lint/test、extension typecheck/lint/format/test、Fast extension 与真实 Pi RPC/codemode 兼容性测试、Server check/test。测试使用临时数据、synthetic OAuth 凭据和 fixture Pi，不调用付费模型。

本轮验证结果：Swift 206 项、account-usage 40 项、PiCompatibility 5 项、Server 80 项，以及 DevWatcher 20 项全部通过；Fast extension 与真实 Pi RPC/codemode sandbox 检查通过。

新增回归覆盖流式超限、错误长度、分片 UTF-8、取消、非法 JSON、状态隔离、复制身份、搜索筛选、刷新屏障及 JSONL 恢复。原有 Swift 格式问题一并规范化，未改变其行为。

本轮没有发布 npm 包、推送远端、安装应用或迁移真实账户。真实浏览器 OAuth、上游额度权限、付费请求和手机端 UI 仍需人工验收。
