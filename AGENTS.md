# Development watcher safety

For multi-step implementation work in this checkout, open a development edit batch **before changing runtime files**:

```sh
python3 scripts/dev.py --begin-edit --label 'short task description'
```

Retain the returned token. Keep that batch open through edits, builds, tests and resolving findings. After the task is complete, close only your batch with `python3 scripts/dev.py --end-edit TOKEN`. These commands do not launch or stop the application. They provide a task-completion barrier for the development watcher; do not rely on pauses between tool calls.

Do not expire, delete or close another worker's batch. If interrupted, leave the batch held and report its token for deliberate recovery (`--status` lists batches). Do not restart the watcher or running application during active tasks; the existing Python watcher must be restarted once, when safe, to load changes to its own script.

See `docs/development-reload.md` for the build/publication and app-idle safety gates.

# 开发规范

- 复杂函数应添加必要的中文代码注释，重点解释设计意图、非显然逻辑和边界条件。
- 删除文件或目录统一使用 trash。
- 能通过一个函数配合参数清晰表达的逻辑，优先使用单一函数，避免仅为转发参数而增加包装函数。

# 代码质量

- 明确区分合法空状态、数据损坏和执行失败，使错误能够被准确发现和处理。
- 测试资源集中在关键业务逻辑、复杂边界条件和高风险流程，保持每个测试都有明确价值。
- 修改 UI 时，提供受影响页面的修改前后对比图，方便我确认变化。
- 外部数据在系统边界完成校验和标准化，内部流程使用完整、可信的静态类型。
- 状态保持单一事实来源，派生数据通过纯函数或计算属性生成。
- 函数参数默认设为必选；仅当业务语义明确允许该参数缺失时使用可选参数。
- 代码保持结构简单、命名清晰、控制流直观，优先可读性。

# 搜索与上下文

- 搜索代码时先缩小目录和关键词范围；需要宽泛搜索时优先使用 `rg -l` 定位候选文件，再读取相关内容。
- 相互独立的搜索和文件读取尽量批量执行，减少碎片化工具调用。
- 临时测试和验证代码统一放在 tmp 目录。
