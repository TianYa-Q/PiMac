---
name: pimac-project
description: 在 PiMac 仓库中开发、排障、重构、测试或发布时先加载。保护原生应用 development watcher 的 edit batch 与发布屏障，保持单用户官方 T3 Server 集成能力，导航 SwiftUI/AppKit 的真实 UI 对比；不适用于公司 ERP 或无项目任务。
---

# PiMac 项目约束与入口

命令在 PiMac 仓库根目录执行。通用核心、执行节奏和 UI 风格由全局 `AGENTS.md`、`development-workflow`、`ui-design` 管理，不在项目内重建 `AGENTS.md`。

## 平台定位与开发管理

PiMac 是软件开发管理的统筹平台，不只是聊天客户端。跨项目的公共能力统一在 PiMac 管理，项目仅保留业务与技术差异，不分散维护同类清理工具。

临时文件管理入口为「设置 → 开发管理」；生命周期遵循全局 `development-workflow`。实现由 `TemporaryFileCleaner.swift`、`TemporaryFilesStore.swift` 和 `TemporaryFilesSettingsView.swift` 维护，`WorkspaceModel` 提供实时项目/worktree 与任务保护，应用每分钟检查是否到达每日（24 小时）的整理周期；跳过或未完成也不进行分钟级重试；关闭应用后不另起守护进程。相关回归为 `TemporaryFileCleanupTests`。策略默认保留 3 天，所有移动进入系统废纸篓；无法确认安全的内容必须保留并在 UI 显示原因。

## 会话关联任务日志

`TaskLogSource.swift` 从当前会话工具输入中识别工作区内明确读取或写入的 `.log`：`read` 路径、本地 `tail` / `head` / `cat` / `tee`，以及 `>` / `>>` / `&>` / `&>>` 输出重定向（支持描述符、字面量 `cd`、引号、管道、后台执行、分号与 `&&`）。只识别字面量目标，不展开变量、通配符、命令替换或复杂 shell 控制流，不解释 SSH / `sh -c` 的嵌套命令；SSH 外层的本地输出重定向可以关联。不从模型回复、日志正文或目录扫描猜路径。默认关联最近一份日志，使用会话 worktree 根目录，不跨会话共享选择。

`TaskLogPanel.swift` 固定在会话输入框上方，默认折叠，仅显示标题栏；展开后独立于 agent 回合每秒读取，折叠后暂停读取，用户上滚暂停滚动跟随。`TaskLogReader.swift` 每次只读末尾 64 KB，支持截断/轮转，普通文件及打开后的实际路径必须在当前工作区内；失败明确显示并保留上次内容，不把文件消失当成成功或空日志。此能力不发起生产连接；远端日志需由另行授权的既有链路取得本地副本，不宣称远端自动订阅。回归入口 `TaskLogTests`、`ToolOutputViewTests`。

## Development watcher 安全

多步实现任务在修改任何运行文件之前，必须打开自己的 edit batch：

```sh
python3 scripts/dev.py --begin-edit --label 'short task description'
```

- 保留返回 token。编辑、构建、测试、截图及处理发现期间始终持有该 batch，不以工具调用之间的停顿作为任务完成依据。
- 完成后只关闭自己的 batch：`python3 scripts/dev.py --end-edit TOKEN`。这两个控制命令不会启动或停止应用，只提供任务完成屏障。
- 不过期、删除或关闭其他 worker 的 batch。中断时保留批次并报告 token；`python3 scripts/dev.py --status` 可查看批次，恢复须明确处理。
- 活跃任务期间不重启 watcher 或正在运行的应用。修改 Python watcher 后，只有全部任务安全空闲时才能重启一次以加载新代码，不能顺手执行。
- 涉及运行文件、原生构建/发布、应用重载或 watcher 时，先读 [开发重载安全门](../../../docs/development-reload.md)。仅调整 skill / 文档不因此启动编译或重启应用。

## 目标架构：原生客户端，最大化复用 T3 Code 逻辑

- 保留 PiMac 原生 SwiftUI/AppKit 客户端；用户明确不希望改用 T3 Code 的 Electron 客户端。复用逻辑以减少 bug，不等于替换客户端或必须采用官方 Web UI。
- 复用边界按 [T3 Code 逻辑复用边界与验收](../../../docs/t3-code-full-reuse.md) 执行。此前“必须完整迁移官方 Electron”的解释已被用户纠正，不再作为实施依据。
- 新需求先核实官方已有实现，优先复用 Server、Provider、协议契约及可解耦客户端逻辑；确需原生适配时保持薄层，用真实契约和回归验证，不另造平行业务状态机。官方升级和修复应能持续合入。

## T3 Server 集成边界

- 本软件为单用户使用；Swift 原生客户端继续保留，客户端适配不得重复实现上游 Server 已承担的业务。
- 不额外限制 T3 Server 的模型、Provider、委派、工具或原生能力；权限和能力判定沿用上游，不添加 PiMac 专属白名单或模型锁。
- 保留上游认证、凭据保护和必要宿主集成；不能因为 UI 尚未展示能力就禁用服务端能力。实际使用子代理仍遵守用户的全局事先询问要求。

## UI 和验证

- UI 设计、修改、截图对比与交付统一加载全局 `ui-design`；涉及 SwiftUI/AppKit/WebKit 原生捕获时，再读 [PiMac 原生捕获接入](references/native-ui-capture.md)，只维护本项目脚本和 fixture 模板，不再单独维护 UI 设计/对比 skill。
- 测试不允许并发：一次只运行一个验证任务；Swift 编译与测试统一使用 `--jobs 1 --no-parallel`（包括隔离截图），Node 使用 `--test-concurrency=1`，Go/esbuild 使用 `GOMAXPROCS=1`。不能把单个测试命令内部的并发编译漏掉。
- 相关 Swift/Node/Python 检查按实际改动与现有入口选择，不把 ERP 的 Vue、Pinia、Electron 或 pnpm 检查套在本项目。
- 真实原生视图、浏览器测试、运行中应用和上游 Server 的验证范围必须明确区分；不为获取截图重启正在工作的应用。
