# Swift 测试一分钟预算

## 交付范围

按最新要求，以一分钟为目标，不再强求删除 80%。保留 659/673 项 Swift 测试（97.9%），移除 14 项；不是跳过、过滤或改成默认不运行。其余语言测试未修改。应用运行时代码未因本任务改变。

当前测试统一使用 `swift test --jobs 1 --no-parallel`：编译单 worker，测试串行，隔离截图也遵循相同限制；不同验证任务不得同时执行。Node 使用 `--test-concurrency=1`，Go/esbuild 使用 `GOMAXPROCS=1`。工具和系统框架内部仍可能有线程，不能把这些设置宣传为 CPU 占用率硬上限。

下文保留调整前使用两个构建 jobs 的历史实测及原始命令，不代表当前允许的执行方式；其时间不能作为单 worker 模式的性能承诺。

## 同条件实测

同一机器、相同 scratch path，命令：

```sh
swift test --scratch-path tmp/performance-usage/swift-build --jobs 2 --no-parallel
```

| 情况 | 命令墙钟耗时 | 结果 |
| --- | ---: | --- |
| 删除前热构建，673 项 | 226.20 秒 | 失败，含既有 OCR 错误 |
| 最终版本热构建，第 1 次 | 57.07 秒 | 659 项全部通过 |
| 最终版本热构建，第 2 次 | 57.17 秒 | 659 项全部通过 |

最终两轮均计入增量构建、测试发现和进程启动，约为基线的 3.96 倍速度。执行内容已减少，不能理解为相同覆盖率下的 3.96 倍性能优化。删除前的失败耗时也包括在基线中，不代表所有改善都来自正常成功路径。

冷构建/源码改动后的重编译不保证一分钟：最终格式化后的第一次运行为 71.30 秒，其中构建 14.34 秒。机器负载也可能使热运行超过预算；当前有约三秒余量，不是硬实时保证。

**整个仓库的 `scripts/check.sh` 不在此一分钟结论内**：它还包括 lint、Python、扩展、兼容性、Server 构建和测试。Server 测试单独运行已超过本轮 180 秒工具预算；其构建检查另报 native runtime stale。全仓 lint 也存在本次修改以外的格式问题。未通过隐藏这些阶段来声称全仓检查达标。

## 删除清单及覆盖损失

以下为实际测试发现清单前后差集，新增项为零。完整删除后的三个空测试文件使用系统 `trash` 回收。

| 测试套件 | 删除测试 |
| --- | --- |
| BrowserPreviewTests | officialServerListAndInteractiveStreamUseAuthenticatedTransport |
| EmptyNewChatTests | createsThreadOnlyOnFirstSendForDesktopAndRemoteDrafts |
| FastModeTests（整文件） | fastSelectionSurvivesRefreshAndReachesPiWithoutChangingThinking |
| GitWorkspaceTests | desktopGitStreamAndDiffReachNativeServerWithoutReplayingFailures |
| GoalCreationTests | nativeStartDispatchesExactCommandsWithoutConsumingComposerOrAttachments |
| HTMLLiveHydrationTests | missingOutputAndDetailFailuresRecoverWithoutReopening |
| HTMLRenderDeliveryTests（整文件） | officialToolPageLoadsLiveAndAfterHistoryRefresh |
| ProjectLifecycleTests | serverConfirmsConcurrentAddArchiveWithoutProjectAndReaddAfterDelete |
| SessionTitleRegenerationTests | emptyConversationRegenerationUsesServerAndClearsProgress |
| SkillCompletionTests | renderedRowsFollowFilteringInsteadOfReusingOldIndex |
| SkillCompletionTests | observedCacheRedrawsRowsWithoutTypingAndKeepsRowsDuringRefreshFailure |
| T3DesktopTests | desktopReconnectsAndRetainsRefreshRequestsDuringPolling |
| T3ImageDeliveryTests | desktopReceivesFileLinksAndDirectImagesFromOfficialServer |
| T3LANServiceTests（整文件） | failedBindReconcilesAndPairingRequiresConfirmedLiveListener |

主要移除多次启动官方服务的功能级端到端检查，以及两项依赖 Vision 硬件初始化且在此环境报 e5rt 错误的截图 OCR 检查。保留官方服务的桌面完整链路、定时任务 RPC 链路、服务重启/超时/符号链接安全、Git 修改安全、认证配置、资源文件边界、草稿恢复及此前新增的十项性能回归测试。

仍有明确覆盖损失：浏览器、图片、HTML、模型快选等各自的原生 UI/官方服务联通性不再由这些已删用例验证；移除 OCR 后也不再自动验证技能列表的实际绘制文字。其余纯逻辑测试不能替代这些端到端与像素层断言。两项 OCR 用例是删除，不是修复 Vision 环境。

## 验证与证据

- 最终每轮：109 XCTest + 550 Swift Testing，全部通过，串行执行。
- 发现清单：673 → 659，精确删除 14 项，无新增、无过滤。
- 修改文件的 `swift format lint --strict` 和 `git diff --check` 通过。
- Python watcher、account-usage 扩展、fast-extension、Pi compatibility 检查通过；全仓 lint 与 Server 检查限制见上。
- 本地日志和清单：`tmp/test-speed/before.json`、`serial-final-{1,2,3}.{json,log}`、`final-inventory.txt`、`inventory-diff.json`。
