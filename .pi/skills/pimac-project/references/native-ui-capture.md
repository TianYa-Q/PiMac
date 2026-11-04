# PiMac 原生页面捕获接入

设计、基线、同条件对比、读图和交付流程统一遵循全局 `ui-design`，本参考只维护 PiMac 专属捕获入口。执行前遵守项目 `pimac-project` 的 edit batch 与 watcher 安全约束；命令在 PiMac 仓库根目录执行。

下文脚本和 assets 路径相对 `.pi/skills/pimac-project/`。项目历史只在复盘时读 [UI 捕获历史](ui-history.md)。

## 原生捕获：默认方案

`scripts/capture.py` 直接在仓库根目录执行正式 `Tests/PiMacAppTests/NativeCaptureTests.swift`，运行真实 `ContentView`，所有任务共用仓库 `.build`。不复制源码、不创建独立 Swift 包、不启动/重启 PiMac App；常规回归默认跳过截图测试，仅脚本通过环境变量启用。截图、日志和来源元数据仍保留在各任务 `tmp/<task>/`。默认 1100×800，暗色。

捕获脚本通过锁拒绝并发截图，SwiftPM 自身负责共用构建目录的构建互斥；所有验证仍须串行执行。捕获期间不要编辑源码；脚本会核对前后源码和 fixture 指纹，变化时明确失败，不认证截图。

准备 `tmp/<task>/fixture.json`，只用无敏感信息的确定性测试数据：

```json
{
  "selectedThreadID": "child",
  "width": 1100,
  "height": 800,
  "theme": "dark",
  "shell": {
    "projects": [{"id":"p","workspaceRoot":"/tmp/pimac-ui-fixture","title":"PiMac"}],
    "threads": [
      {"id":"parent","projectId":"p","title":"父任务","status":"completed","createdAt":"2026-10-11T00:00:00Z","updatedAt":"2026-10-11T00:00:00Z"},
      {"id":"child","projectId":"p","title":"子代理任务","status":"running","createdAt":"2026-10-11T00:01:00Z","updatedAt":"2026-10-11T00:01:00Z","lineage":{"relationshipToParent":"subagent","parentThreadId":"parent"}}
    ]
  }
}
```

```sh
CAPTURE=.pi/skills/pimac-project
python3 "$CAPTURE/scripts/capture.py" --fixture tmp/<task>/fixture.json --output tmp/<task>/before.png
# 完成修改后，同一 fixture、同一仓库构建缓存：
python3 "$CAPTURE/scripts/capture.py" --fixture tmp/<task>/fixture.json --output tmp/<task>/after.png
python3 "$HOME/.pi/agent/skills/ui-design/scripts/compare.py" --before tmp/<task>/before.png --after tmp/<task>/after.png --output tmp/<task>/comparison.png
```

- 选中子会话可通过真实 `ContentView` 的 reveal 逻辑展开祖先；不要为截图修改正式 UI 的可见性。
- 如果页面不是 `ContentView`，在正式捕获测试中增加对应 fixture 渲染路径，复用同一 `.build`；保留隔离初始化和释放逻辑。不适用的 fixture 应明确失败，不能悄悄截图另一页。
- 不再支持 `--workspace`、`--test-template`、`--baseline-ref` 或 `--baseline-file`，避免重新引入复制构建或临时覆盖共享源码。忘记改前截图时明确报告缺少基线，不要用 git checkout/reset/stash 覆盖工作区，也不要拿 HEAD 覆盖别人的未提交改动。
- 如真实运行环境无法安全复现，fixture 渲染是**真实组件的测试数据截图**，不是运行中应用截图。HTML/CSS 重画只是示意图，不能代替原生修改证据；必须说明降级和未验证项。

