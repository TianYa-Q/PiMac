# 标题生成模型设置

“模型与思考等级 → 标题与辅助文本”使用官方 `textGenerationModelSelection`。
这不是仅用于标题的新字段：官方还用它生成分支名称等辅助文本。它不修改对话模型，也不改独立的 `sourceControlWriterModelSelection`。

- 选择列表来自官方 Registry 中 `pi` 实例的具体模型，排除上游 `default` 哨兵和已隐藏模型。隐藏仅影响选择界面，不删 Registry/运行时能力。
- 选择通过带宿主凭据的回环管理接口写入官方 `ServerSettingsService.updateSettings`；没有额外的 UserDefaults/JSON 标题模型偏好。
- 仍可用的显式 Pi 选择及其 options 在读取、重连、重启后保持原样。当前选择被隐藏/下架时，改用目录顺序中的第一个仍显示的具体 Pi 模型；不会转向其他 Provider。
- 没有候选模型时显示明确待配置状态。由于官方字段不可为 null，不写入假模型或清空字段；标题执行入口会重新校验目录，并在没有可用 Pi 选择时停止自动标题，而不调用 Codex。
- 启动探测、目录损坏和保存失败与合法空候选区分：失败显示错误，保留已确认快照，要求重新读取。离线不写回设置。
- 自动标题执行前再次读取已确认的官方选择，覆盖仅在本次调用中已过期的快照，避免“隐藏模型后第一次标题”仍调用旧模型。其他 Provider、MCP、委派、认证和独立的源码控制模型能力不受此标题路径影响。

验证：`node --test sidecars/t3-server/tests/text-generation-{settings,management}.test.mjs`；`swift test --filter TextGenerationModelSettingsTests`。
截图：`tmp/title-model-ui/`，是真实原生设置组件的隔离 fixture（不是真实账户或运行中应用）。
