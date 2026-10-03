# PiMac / account-usage 稳定性与体验优化

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

## 验证与边界

运行 `./scripts/check.sh`：Swift lint/test、extension typecheck/lint/format/test、Fast extension 与真实 Pi RPC/codemode 兼容性测试、Server check/test。测试使用临时数据、synthetic OAuth 凭据和 fixture Pi，不调用付费模型。

本轮验证结果：Swift 206 项、account-usage 40 项、PiCompatibility 5 项、Server 80 项，以及 DevWatcher 20 项全部通过；Fast extension 与真实 Pi RPC/codemode sandbox 检查通过。

新增回归覆盖流式超限、错误长度、分片 UTF-8、取消、非法 JSON、状态隔离、复制身份、搜索筛选、刷新屏障及 JSONL 恢复。原有 Swift 格式问题一并规范化，未改变其行为。

本轮没有发布 npm 包、推送远端、安装应用或迁移真实账户。真实浏览器 OAuth、上游额度权限、付费请求和手机端 UI 仍需人工验收。
