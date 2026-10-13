# 历史依据（2026-10-12 整理）

这些结论来自 PiMac 的真实会话及遗留 tmp 捕获脚本，不是通用网页 mockup 流程。

## 侧栏重设计与 HTML 展示修复

会话 `41C00FC7-D458-47F7-B5A6-DEE485235867`（2026-10-11）：

- 先改布局并调用 HTML 展示，用户仍追问为什么没有前后图。工具成功返回不能证明 PiMac 客户端渲染成功。
- 随后直接交付 `tmp/sidebar-comparison-before.png`、`tmp/sidebar-comparison-after.png`，明确说明旧基线的示例数据不同。
- 调查发现当时桌面端缺 HTML 展示入口；之后接入实时/历史渲染，交付 `html-render-comparison.png` 和 `sidebar-refinement-comparison.png`。
- 留下 `tmp/SidebarRedesignVisualTests.swift`：真实 `ContentView`，fixture shell、多项目/长标题/运行中会话，1100×800、暗色，`NSHostingView` + `NSWindow` + `cacheDisplay` 输出 PNG。

教训：HTML 是交付容器，不是原生截图的替代；不要沿用“PiMac 永远不支持 HTML”的过时结论，也不要相信“已展示”的单一返回值。

## 子代理层级

会话 `61E4B82C-10B5-4DA7-9D6B-CD8CE0E5FE8F`：

- `tmp/SubagentSidebarVisualTests.swift` 用 fixture 的服务端 lineage 注入父/子/普通会话。
- 临时 Swift 在 tmp，通过符号链接进入 test target，运行 `SUBAGENT_VISUAL_PHASE=... swift test --filter SubagentSidebarVisualTests`。
- 用 accessibility 找展开按钮曾遇到 API 类型错误及找不到控件；最后通过选中子会话触发真实祖先展开逻辑成功渲染。
- 输出前后、展开截图，使用相同 crop 坐标裁侧栏；截图结束用 `trash` 移除临时测试入口，再运行业务测试。

本 skill 保留真实 fixture 捕获，改为**隔离副本**，免去在正式 Tests 插链接、临时恢复当前源码的风险。

## 已查看完成状态

会话 `AB411693-DCED-4866-9E33-98E93BCF4E8A`：

- `tmp/ViewedCompletionVisualTests.swift` 固定两个完成会话；选中 viewed，另一个作为后台未读对照。
- 前后同场景，配合 UnreadCompletionTests/T3V2PresentationTests 验证行为。
- 不只是画新颜色，还需要验证“当前会话不再提示、其他未读会话仍提示”的状态边界。

## 拼图与 WebKit 的既有样例

- `tmp/settlement-comparison.py`：Pillow 裁两个 PNG、等尺寸并排、中文标题、保存 comparison。
- `tmp/HTMLImagePreviewVisualTests.swift`：真实 WebKit 图片预览使用 `WKWebView.takeSnapshot`，并验证缩放；说明 Web 内容不一定能仅靠 host cacheDisplay 得到正确画面。
- 所有 tmp 样例只是历史参考，可能已被清理或 API 已变化；当前 skill 的模板和脚本为可复用入口，不能要求历史文件永远存在。
