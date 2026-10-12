# 模型上下文限制

「模型与思考等级」默认勾选「仅已显示」。取消勾选仍可管理隐藏模型。

每个模型的「上下文限制 · tokens」按钮显示额度及来源：未覆盖时显示 Pi 默认 token 数，覆盖时显示手工值。编辑弹窗也显示已获取的默认额度，供输入时参考。可以保存正整数总上下文预算；留空或点击「恢复默认」移除覆盖。

默认额度来自 Pi RPC 模型发现的原始 `contextWindow`，并非根据当前会话使用量或服务端配额推算。刷新模型列表会重读这份元数据；它不是强制远程更新。Pi 没有上报额度时显示「未获取大小」，不使用 0 或猜测值。已覆盖模型若只返回覆盖后的额度且没有基础默认值，则默认额度保持未知，不能冒充 Pi 默认。

- 本机 Server 写入 Pi agent 目录的 `models.json`：`providers[provider].modelOverrides[modelId].contextWindow`。
- 默认目录为 `~/.pi/agent`；遵循 Server 的 `PI_CODING_AGENT_DIR` 环境变量。设置是全局的，并非单个线程的配置。
- `modelOverrides` 是 Pi 的模型元数据覆盖层，适用于已有内置、远程及自定义模型。未知模型 ID 不会新增模型。
- 保存仅修改目标模型的 `contextWindow`，保留凭据、API 配置、模型定义及其他覆盖字段。恢复默认会回到 Pi 原有定义（包括自定义模型的基础值）。
- 缺失文件视为未设置；损坏 JSON、错误结构或无效已有覆盖会报错，不会被当作空配置覆盖。文件采用私有权限的原子写入。
- 桌面管理端点需要本机 supervisor 凭据；不新增公开或手机端配置写入接口。

此设置作用于 Pi 的总上下文预算及自动压缩判断，不只是桌面显示。它不修改 `maxTokens`、`reserveTokens` 或 `keepRecentTokens`，也不能增加模型服务端真实额度。

保存不会中断或重启任何正在执行的线程。新的 Pi 进程读取新配置；已打开会话不会立即改变上下文上限。刷新模型列表会重新读取配置，但不是强制刷新运行中会话。

## 验证

- `ModelContextLimitTests`：空值、正整数标准化及 Swift/JS 数字边界。
- `sidecars/t3-server/tests/model-context.test.mjs`：原子保存、重读、恢复默认、保留其他字段、损坏配置、符号链接保护，以及默认额度和手工覆盖的区分、移除模型后的快照更新。
- `sidecars/t3-server/tests/model-context-management.test.mjs`：隔离 agent 目录下通过真实桌面管理 HTTP 端点保存、拒绝无权访问及非法输入。
- `tmp/verify-model-context-runtime.mjs`：在本机 Pi 1.0.2 真实运行时中离线验证覆盖和恢复自定义模型基础值；不调用模型 API、不修改用户配置。
- 上下文限制页面原始对比图位于 `tmp/model-settings-before.png`、`tmp/model-settings-after.png`、`tmp/model-context-editor.png`；默认额度显示的对比图位于 `tmp/model-default-context-before.png`、`tmp/model-default-context-after.png`、`tmp/model-default-context-editor.png`。
