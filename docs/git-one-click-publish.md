# 一键提交并推送

底部 Git 入口改为「提交并推送」，不再弹出源代码管理面板。核对代码、分支管理和冲突处理留在 VS Code。

## 行为

- 使用点击时选中线程的 worktree，未绑定 worktree 时使用项目目录。
- 先刷新状态，然后调用官方 `git.runStackedAction`，action 为 `commit_push`。
- 不传 `commitMessage` 或 `filePaths`：官方 Server 根据整个工作区生成说明、暂存全部变更（含未忽略的新文件和删除）、执行 hooks、commit、push。
- 生成模型与写作风格沿用 Server 的源代码写作设置及其官方辅助文本模型回退，不依赖 VS Code / Copilot。
- 整个流程（含刷新）持有 Git busy 锁，防止重复点击、交叉刷新和开发热载中断。按钮旁显示固定类别进度，不展示可能含凭据的 hooks 原始输出。
- 工作区无改动且已与上游同步时直接提示无事可做；没有工作区改动但有待推送提交时仍执行流程，由 Server 跳过 commit 后推送。
- 不增加自动 pull、冲突解决、强推或失败自动重试。断线/失败可能发生在 commit 之后，不宣称回滚或未提交；提示用户核对，再次明确点击会先获取新状态。
- 收到完整的 commit/push 结果且刷新成功后才显示「已提交并推送」。结果缺失或最终刷新失败单独报告。

## 验证与截图

`GitPublishTests` 验证全工作区参数、上下文、操作锁、无改动、有待推送提交、无效快照、detached HEAD、失败/损坏结果、失败后的明确重试与最终刷新失败。Git 相关 6 个 suite 共 35 项测试通过（包含 Swift 编译/typecheck）；3 个改动 Swift 文件的严格 lint 和 `git diff --check` 通过。

本次 UI 证据位于 `tmp/git-publish/*-component.png`：按源码原样提取真实 SwiftUI 按钮及其 modifier，在独立包中固定尺寸/主题渲染。修改前取自任务开始时干净的 HEAD（重建基线）；修改后覆盖空闲、执行中、成功、失败。没有连接真实 Server，因此按钮为断线禁用样式，不代表真实提交已发生。

整页原生 fixture 的输入区未正常渲染，系统窗口截屏也不可用，因此未把空白整页图作为有效证据；完整页面布局和真实账户的生成/远端推送仍需实机验收。没有重启应用，没有对当前仓库执行 commit/push。

全量 Swift 测试在 `T3DesktopTests.desktopUsesNativeLoopbackServerWithoutPublicAdministration` 中因 currentSessionPath 断言和后续强制解包崩溃；单独纳入该测试重跑仍复现，未改动这个任务范围外的测试。
