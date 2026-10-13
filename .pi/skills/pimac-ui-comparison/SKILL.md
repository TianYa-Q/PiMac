---
name: pimac-ui-comparison
description: PiMac 专属 UI 修改前后对比流程。修改 SwiftUI/AppKit/WebKit 页面、侧栏、状态标记、布局或交互展示时使用；固定数据渲染真实原生页面，安全截图、裁剪拼图并确认图片交付，不重启正在工作的应用。
compatibility: macOS、Xcode/Swift、Python 3；拼图需要 Pillow。
---

# PiMac UI 对比

路径相对本 skill；命令在 PiMac 仓库根目录执行。先读项目 `AGENTS.md` 和 `docs/development-reload.md`。历史依据见 `references/history.md`，无需每次重查旧会话。

## 标准流程

1. **先确定场景和基线**：检查 `git status`，记录本任务涉及的文件。截图前固定窗口尺寸、主题、项目筛选、选中会话、树展开、滚动位置及业务数据。状态改动至少验证触发前、触发中、结束后；不能只截图正常空闲页。
2. **先开 edit batch 再改运行文件**：`python3 scripts/dev.py --begin-edit --label 'UI task'`，保留自己的 token。批次一直持有到编辑、构建、验证和截图结束；不重启 watcher/正在运行的应用，不释放别人批次。
3. **改前截图**：优先使用真实视图加确定性 fixture。使用下方隔离捕获脚本，不修改正式测试目录，不切换当前 checkout，不接入真实账户/Server。修改前就保存 PNG；不要等到结束才找基线。
4. **修改并验证**：聚焦业务断言和高风险边界；运行相关 `swift test --filter '...'`。截图成功不等于业务测试通过。同一个 fixture、尺寸及主题捕获 after。
5. **看图而非只看退出码**：用 `read` 检查 PNG，确认不是白屏、裁错区域、仍是旧版本或加载占位。WebKit/异步内容需等明确就绪事件或有限等待；必要时用 `WKWebView.takeSnapshot`，不能无限延长 sleep。
6. **裁剪/拼图**：坐标以实际 PNG 像素为准（Retina 常为逻辑尺寸的两倍），两边使用相同区域与缩放比例。保留原始 before/after，另生成 comparison；中文标明“修改前 / 修改后”。小改动聚焦局部，必要时另附全页。不要把旧会话不同数据拼图伪装成严格同条件对比。
7. **清理与完成**：临时 Swift、JSON、PNG、日志、构建全部放 `tmp/<task>/`；需要删除用 `trash`，不删除别人的文件。`git diff --check`，完成后 `python3 scripts/dev.py --end-edit TOKEN`。任务中断则报告持有的 token。
8. **交付**：提供真实 PNG 的 Markdown 图片引用，或按当前工具要求先 `html_preview` 再 `html_render` 展示截图拼图。仅 read 图片、工具返回“已展示”或文字写“附图”都不等于已交付；未经客户端验证不要声称用户已看到。HTML 交付可保留 PNG 下载/查看链接作回退。遵守截图工具要求（浏览器截图必须 `preview_snapshot(save:true)` 才有可交付路径）。

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
SKILL=.pi/skills/pimac-ui-comparison
python3 "$SKILL/scripts/capture.py" --fixture tmp/<task>/fixture.json --output tmp/<task>/before.png --workspace tmp/<task>/capture-package
# 完成修改后，同一 fixture、同一独立包：
python3 "$SKILL/scripts/capture.py" --fixture tmp/<task>/fixture.json --output tmp/<task>/after.png --workspace tmp/<task>/capture-package
python3 "$SKILL/scripts/compare.py" --before tmp/<task>/before.png --after tmp/<task>/after.png --output tmp/<task>/comparison.png
```

- 选中子会话可通过真实 `ContentView` 的 reveal 逻辑展开祖先；不要为截图修改正式 UI 的可见性。
- 如果页面不是 `ContentView`，复制 `assets/NativeCaptureTests.swift` 到本任务 tmp，调整 rootView 及环境对象，通过 `--test-template` 使用；保留隔离初始化和释放逻辑。不适用的 fixture 应明确失败，不能悄悄截图另一页。
- 忘记改前截图时：仅对**确认任务开始时与指定 ref 一致的文件**使用 `--baseline-ref HEAD --baseline-file Sources/PiMacApp/ContentView.swift` 重建基线（参数可重复）；只覆盖独立副本。明确写“从 ref 重建的原生基线”，不要用 git checkout/reset/stash 覆盖工作区，也不要拿 HEAD 覆盖别人的未提交改动。
- 如真实运行环境无法安全复现，fixture 渲染是**真实组件的测试数据截图**，不是运行中应用截图。HTML/CSS 重画只是示意图，不能代替原生修改证据；必须说明降级和未验证项。

## 完成检查

- [ ] before/after 为真实视图、同条件，或明确说明基线限制。
- [ ] 实际读图，窄宽度/长标题/状态变化等受影响边界检查完成。
- [ ] 相关测试通过，失败和未验证项如实记录。
- [ ] 有可见图片交付，不仅本地文件路径或工具成功提示。
- [ ] 当前工作区未被截图流程还原/切换；只释放自己的 edit token。
