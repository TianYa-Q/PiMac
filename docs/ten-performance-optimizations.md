# 十项性能优化验收（2026-10-23）

## 验收口径

本轮新增十项优化，不重复计入上一轮的 `T3UsageSummary` 日期缓存。每项在**明确列出的同条件合成工作负载**中，完整目标调用的耗时至少减半（速度超过 2×），而不是声称所有输入、真实用户会话或整个 App 都快两倍。

任务开始时工作区干净，基线 HEAD 为 `3ab07ca3fc024095ac12261f7b803477a096f62e`。实际修改前复制源码并执行基线，保留在 `tmp/performance-ten/baseline`。没有切换/还原当前工作区，没有使用子代理、修改上游 Server 或限制其能力，没有重启正在工作的应用/watcher。

## 结果

Apple Silicon、Apple Swift 6.4，完整应用在隔离 Swift 包中以 `swift test -c release` 编译。每项先预热一次，再取七个样本的中位数。每个样本执行 1–3 次（见临时基准代码）后折算单次时间。生成输入、编译、网络和 UI 截图不计入时间；目标调用后的输出序列化及一致性断言计入时间。

原始记录为 `before.json` 与 `after-final.json`；另有不重新编译的复跑 `after-repeat.json`。下表使用第一轮最终结果，最后一列是两轮速度比的较低值。计量单位为毫秒。

| # | 优化点与合成负载 | 修改前 | 修改后 | 首轮速度比 | 两轮较低速度比 |
|---|---|---:|---:|---:|---:|
| 1 | 工具树：500 层显式父子工具链 | 1.090 | 0.461 | 2.36× | 2.32× |
| 2 | 时间线：8,000 条消息、600 个任务边界 | 13.675 | 5.025 | 2.72× | 2.63× |
| 3 | 回复图片路径：1,500 行普通正文及一个图片链接 | 16.738 | 2.642 | 6.34× | 6.27× |
| 4 | 内联图片匹配：2,000 个附件、500 个链接 | 14.237 | 1.595 | 8.93× | 8.93× |
| 5 | Telegram：100 份中英文/emoji/转义混合正文 | 7.826 | 0.844 | 9.28× | 9.28× |
| 6 | 旧历史导入：1,000 条带 ISO 毫秒时间戳消息 | 284.812 | 69.961 | 4.07× | 4.04× |
| 7 | 上下文统计：300 条乱序日期压缩观测 | 250.632 | 19.205 | 13.05× | 13.05× |
| 8 | 排队消息关联：1,500 个排队 run、1,500 条消息 | 88.565 | 1.362 | 65.01× | 65.01× |
| 9 | Markdown：400 行中英文普通正文 | 12.352 | 4.773 | 2.59× | 2.59× |
| 10 | JSONL 分帧：4 MiB 单条无 LF 数据及后续短记录 | 2.101 | 0.101 | 20.90× | 20.90× |

十项基准各自的前后输出完全一致。数据刻意覆盖低效路径，并非真实用户数据规模的统计；例如 500 层工具树、2,000 个附件和 1,500 个排队 run 都属于压力场景，不代表日常会话。旧历史导入只服务于兼容导入，不是实时 Server 聊天路径。不应把这些倍率相加或当作应用整体加速。

## 实现及保留的语义

1. `Models.swift / ChatEntry.groupingToolEntries`：不再逐层复制祖先集合；只有重复 ID 可能让从根可达的关系带环，此时仍用路径集合防环。单子节点无需排序，移除 filter/map 中间数组。保持孤儿提升、兄弟排序及原来不可达环的行为；仍使用递归，不宣称解决任意深度的栈限制。
2. `ConversationSubagents.swift / ConversationTimelineRow.build`：单遍建立前缀最大时间的跃迁点，对每个任务二分定位。不是假设消息有序；缺失、相同及乱序时间仍返回原数组中首个严格更晚的消息。无子任务时直接分组，不建索引。
3. `T3ReplyImageLinks.swift / paths`：复用不可变正则，普通无链接行提前跳过，仅出现反引号才移除行内代码。围栏状态先更新，保留文件读取安全边界、去重及 8 张限制。
4. `MarkdownReplyImages.swift / parts`：复用正则，仅遇到实际本地图片路径才懒建附件索引。同路径仍选第一个图片附件，非图片不占位；缺失/远程/代码链接保持原文。
5. `TelegramMarkdown.swift / inline`：普通正文连续成段转义，不再逐字符调用六种标记匹配和四轮 Foundation 替换。原标记、链接、安全转义、Unicode grapheme 行为不变。
6. `LegacyTranscript.swift / recordDate`：复用秒级及毫秒级 ISO formatter，以锁串行保护后台并发导入，不共享未保护的可变解析器。不缓存解析结果，不改变时间格式或无效值回退规则。
7. `T3V2Presentation.swift / contextMetrics`：在 MainActor 内复用日期解析器，每条候选只解析一次并单遍取最大值，保持相同时间取第一项、只接受本线程有效已完成观测及新用量优先规则。
8. `T3V2Presentation.swift / detail`：排队 run 与消息按 ID 建立索引连接，避免 N×M 扫描。重复 ID 保留第一个、缺失 ID 保留原 nil==nil 的匹配行为；无队列不建索引，不改变排队次序或服务端身份。
9. `MarkdownView.swift / MarkdownParser`：正文先快速排除分隔线、数字列表和表格分隔符的候选，避免多次扫描/复制整行。合法候选仍走原解析器，不简化 Markdown 规则；保留带符号数字、空格分隔的减号及 Unicode。
10. `JSONLineDecoder.swift / append`：用 libc `memchr` 按块寻找新增字节中的 LF。仍保留跨读取缓冲、CRLF、最大记录字节、超限丢弃到 LF 后恢复、无终止行 EOF flush 和 Unicode 分隔符不拆帧的语义。

额外索引均为单次调用派生数据，不是持久化状态。时间线额外空间随消息的前缀最大时间跃迁数增长；图片及队列索引随各自输入数量增长。本轮未实测峰值内存、真实 UI 卡顿时长、网络延迟或所有小输入场景。浅工具树、无队列、无链接等不同输入不保证 2×。

## 回归验证

- 正式新增 `Tests/PiMacAppTests/PerformanceRegressionTests.swift`，十项关键语义测试覆盖重复 ID 环、兄弟路径隔离、乱序/缺失/相同时间、图片围栏/去重、同路径首图、Unicode/HTML 转义、并发旧历史导入、压缩时间平手、队列重复/缺失 ID、特殊 Markdown 和 JSONL 每个切分位置的超限恢复。
- 最终相关回归为 **83 项 Swift Testing + 6 项 XCTest，全部通过**，日志 `tmp/performance-ten/final-targeted-tests.log`。筛选包含相关测试文件中的函数名，避免遗漏顶层 `@Test`。
- 临时差分测试从原始源码提取旧实现，与新实现比较：600 份确定种子的混合 Markdown/Unicode/代码/链接文本；200 组重复 ID/环工具图、乱序时间线和压缩项。全部通过，日志 `final-differential-tests.log`。临时代码不放正式测试目录。
- 全量应用及测试目标编译成功。全量 **109 项 XCTest 全通过**；**564 项 Swift Testing 出现 8 issues，涉及 5 项测试**，日志 `full-tests.log`。不能称全量全绿。
- 三项超时/时序失败单独重跑通过：`explicitDisableSurfacesRestoreFailureAndBlocksOverlappingActivation`、`startupDeadlineStopsChildAndAllowsRetry`、`desktopReconnectsAndRetainsRefreshRequestsDuringPolling`。
- SkillCompletion 两项 OCR 测试在缩小范围重跑后仍抛出 Vision 的 `e5rt_execution_stream_operation_create_precompiled_compute_operation_with_options call failed`（13），未解决；相同错误在上一轮本任务修改前的 `tmp/performance-usage/full-tests.log` 中也出现过。本轮未修改其代码或 Vision 环境。
- 修改文件的 `swift format lint --strict`、`git diff --check` 通过。未运行完整跨语言 `scripts/check.sh`，本轮没有修改扩展或 sidecar。

## 原生对比

未做视觉/交互改版。仍按 UI skill 用隔离包渲染真实 `ConversationSubagentsView` 和 `MarkdownView`，固定输入、1100×850、浅色主题；保存 PNG 后实际读图。before 是从任务起始 ref 重建的**原生组件 fixture 基线**，不是在线应用截图；同条件 after 与 before 逐像素一致。

- `tmp/performance-ten/before-components.png`
- `tmp/performance-ten/after-components.png`
- `tmp/performance-ten/comparison.png`（同区域裁剪拼图）

整页 ContentView 的离屏截图曾出现原生材质/文字空白，不作为视觉通过证据；没有为此改正式 UI 或重启应用。最终交付的是可读的真实受影响组件，而非 HTML 重画。

## 复现资源

所有临时资源均在 `tmp/performance-ten/`：

- `BenchmarkTests.swift`、原始/最终 JSON 和各轮日志；`before.json` 在运行时代码修改前生成。
- `baseline/Sources` 为修改前源码；`capture-package` 为当前隔离包，包含临时基准、差分测试和原生捕获测试。
- `create-differential.py` 可从保存的原始源码生成差分测试；固定随机种子，不访问账户或网络。
- 若要重新测量旧版，应将 `baseline` 的独立源码复制到新的 tmp 包并放入同一份基准，不能把当前源码运行结果覆盖标记为 before，也不要还原正在工作的 checkout。

当前优化版复跑：

```sh
PERF_REPORT="$PWD/tmp/performance-ten/recheck.json" \
  swift test --package-path tmp/performance-ten/capture-package -c release \
  --skip-build --filter PerformanceBenchTests
```

去掉 `--skip-build` 可从当前隔离包源码重新编译。修改隔离包源码之前需先从当前 `Sources` 同步，基准与运行 checkout 并不是自动同步的。
