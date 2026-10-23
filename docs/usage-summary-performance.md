# 用量汇总性能优化（2026-10-23）

## 排查范围与选择

本轮只读检查了 JSONL 拆分、历史缓存、会话树、对话分组、Telegram Markdown、旧用量扫描及 T3 用量汇总。没有对正在使用的应用做 profiler 采样，以下优先级是代码路径分析加合成基准，不是全应用热点排名。

- **P1，已测量并优化：`T3UsageSummary.snapshot` 的重复日期解析。** 同一天按模型及来源分桶时，每个桶都调用 `DateFormatter.date(from:)`。年度合成数据中，43,800 桶只有 365 个不同日期，日期解析可从 43,800 次降为 365 次。该方法由桌面客户端获取用量汇总后调用，重复解析不提供额外业务价值。
- **P2，待测量，不改：`ConversationTurn.group` 的向后查找。** 在带有 run ID、混有大量缺失 run ID 项的长轮次内，`current.last(where:)` 可能重复扫描。尚未确认实际数据分布及收益，涉及轮次边界，不在本轮扩大修改。
- **P2，待测量，不改：`TelegramMarkdown.html` 的表格候选后缀解析。** 连续包含管道符但不构成表格的行可能重复扫描后缀。尚未证实实际负担及兼容边界。
- JSONL 解码已有仅扫描新增字节的处理；会话树已有迭代遍历和根路径复用；历史缓存有容量上限，本轮未找到值得直接修改的证据。

## 改动与边界

`Sources/PiMacApp/T3UsageSummary.swift` 新增本次调用内的 `[String: Date]`，对相同日期字符串复用解析结果。缓存不跨请求、不跨时区；日期解析规则、桶结构校验、聚合规则、空响应、损坏响应报错、费用及会话数算法均保持不变。额外内存随本次响应不同日期字符串数增长，调用结束释放；没有收益的独立日期场景保留作对照。

本轮没有修改 SwiftUI/AppKit/WebKit 视图、布局或交互展示，因此不涉及 UI 前后截图。没有修改 T3 上游、限制 Server 能力，也没有触碰开始任务时已有的其他未提交改动。未使用子代理，未重启正在工作的应用或 watcher。

## 基准方法与结果

环境：Apple Silicon，Apple Swift 6.4（swiftlang-6.4.0.34.1），`swiftc -O`。

`tmp/performance-usage/benchmark.py` 直接编译真实的 `T3UsageSummary`、`UsageArithmetic`、`AccountUsageSnapshot`，并从 `UsageDashboard.swift` 提取原始数据类型。仅用一个同名错误枚举替代 RPC 客户端依赖；不模拟汇总实现。相同的 UTC 合成输入在计时前创建，一次预热后测量七次完整汇总，取中位数；断言请求总数、总 Token、日期数及模型数。均不含编译、网络、JSON 解码或输入生成时间。

原始基线测量在运行时代码修改前保存为 `before.swift` / `before.txt`。再次顺序运行同一对优化编译二进制（未与构建/测试并行）得到：

- 7 天 × 20 模型 × 3 来源，共 420 桶：23.327 ms → 1.455 ms，约 16.0 倍，耗时降低约 93.8%。
- 365 天 × 40 模型 × 3 来源，共 43,800 桶：2462.549 ms → 117.502 ms，约 21.0 倍，耗时降低约 95.2%。
- 1,000 天 × 1 模型 × 1 来源，无重复日期：56.702 ms → 57.385 ms，约增加 1.2%；此场景没有日期复用收益，仍需额外字典操作。

原始样本保存在 `tmp/performance-usage/{before,after,before-repeat,after-repeat}.txt`，不是实际用户历史规模或端到端 UI 加速的承诺。尚未测量真实账户数据、CPU、峰值内存或运行中页面响应。

### 本地复现

本轮基线对应 HEAD `e3e8c90e27ac3688f7bc1b7f7e0677b9d103ef94` 中的 `T3UsageSummary.swift`；该文件在任务开始时无本地改动。

保留的基线/优化独立 Swift 文件可以重新编译运行，不需要还原工作区：

```sh
swiftc -O tmp/performance-usage/before.swift -o tmp/performance-usage/before
swiftc -O tmp/performance-usage/after.swift -o tmp/performance-usage/after
tmp/performance-usage/before
tmp/performance-usage/after
```

`python3 tmp/performance-usage/benchmark.py <新标签>` 可从当前源码生成新一轮基准。不要使用 `before` 标签覆盖已保存的原始基线。临时资源全部在 `tmp` 中，不作为正式测试代码提交。

## 回归与局限

新增三项业务测试，验证重复日期跨模型/来源不会丢桶、时区与夏令时切换及连续请求隔离、命中缓存后依然拒绝损坏桶且接受合法空响应。

- 完整应用及全部 Swift 测试目标编译成功。
- 最终相关回归命令通过，24 tests / 4 suites，零失败：
  `swift test --scratch-path tmp/performance-usage/swift-build --filter 'T3UsageSummaryTests|UsageSafetyTests|UsageDashboardTests|AccountUsageSnapshotTests'`。
- `swift format lint --strict Sources/PiMacApp/T3UsageSummary.swift Tests/PiMacAppTests/T3UsageSummaryTests.swift` 通过。
- `git diff --check` 通过。
- 全量 Swift Testing 执行了 554 tests / 108 suites，出现 7 issues，涉及 4 个测试：SkillCompletion 两项 `e5rt` 执行错误、LidSleepController 一项恢复等待断言、T3Lifecycle 一项启动超时测试（3 issues）。不是全量全绿；日志为 `tmp/performance-usage/full-tests.log`。
- 缩小范围重跑后，SkillCompletion 和 T3Lifecycle 通过；LidSleepController 单项再跑通过。对应 `retry-tests.log` 和 `lid-isolated-test.log`。这些结果显示失败与环境/时序有关，但没有用优化前全量运行证明其基线状态；本轮不修改无关生命周期与模型运行环境代码。
- 未运行完整 `scripts/check.sh`（包括扩展及 sidecar 的其他语言检查），本轮没有修改这些模块。
