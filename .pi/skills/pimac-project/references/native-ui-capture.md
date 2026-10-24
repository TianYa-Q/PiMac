# PiMac 原生页面捕获接入

设计、基线、同条件对比、读图和交付流程统一遵循全局 `ui-design`，本参考只维护 PiMac 专属捕获入口。执行前遵守项目 `pimac-project` 的 edit batch 与 watcher 安全约束；命令在 PiMac 仓库根目录执行。

下文脚本和 assets 路径相对 `.pi/skills/pimac-project/`。项目历史只在复盘时读 [UI 捕获历史](ui-history.md)。

## 原生捕获：默认方案

`scripts/capture.py` 将当前 `Package.swift`、`Sources` 和捕获测试复制到独立 `tmp` 包，运行真实 `ContentView`。不会启动/重启 PiMac App，不改当前运行源码或正式 Tests；会编译一次独立包，before/after 复用其构建缓存。默认 1100×800，暗色，输出 PNG 和来源元数据。

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
python3 "$CAPTURE/scripts/capture.py" --fixture tmp/<task>/fixture.json --output tmp/<task>/before.png --workspace tmp/<task>/capture-package
# 完成修改后，同一 fixture、同一独立包：
python3 "$CAPTURE/scripts/capture.py" --fixture tmp/<task>/fixture.json --output tmp/<task>/after.png --workspace tmp/<task>/capture-package
python3 "$HOME/.pi/agent/skills/ui-design/scripts/compare.py" --before tmp/<task>/before.png --after tmp/<task>/after.png --output tmp/<task>/comparison.png
```

- 选中子会话可通过真实 `ContentView` 的 reveal 逻辑展开祖先；不要为截图修改正式 UI 的可见性。
- 如果页面不是 `ContentView`，复制 `assets/NativeCaptureTests.swift` 到本任务 tmp，调整 rootView 及环境对象，通过 `--test-template` 使用；保留隔离初始化和释放逻辑。不适用的 fixture 应明确失败，不能悄悄截图另一页。
- 忘记改前截图时：仅对**确认任务开始时与指定 ref 一致的文件**使用 `--baseline-ref HEAD --baseline-file Sources/PiMacApp/ContentView.swift` 重建基线（参数可重复）；只覆盖独立副本。明确写“从 ref 重建的原生基线”，不要用 git checkout/reset/stash 覆盖工作区，也不要拿 HEAD 覆盖别人的未提交改动。
- 如真实运行环境无法安全复现，fixture 渲染是**真实组件的测试数据截图**，不是运行中应用截图。HTML/CSS 重画只是示意图，不能代替原生修改证据；必须说明降级和未验证项。

