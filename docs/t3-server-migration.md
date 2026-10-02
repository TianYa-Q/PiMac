# T3 Server 底层架构迁移

```text
桌面 SwiftUI / T3 iOS / Telegram
              ↓ 原生 HTTP / RPC 命令与读取
T3 Server：原生编排、事件存储、回执、投影、reactors
              ↓ Pi Provider Adapter
Pi RPC runtime（Server 独占进程和会话）
```

## 所有权

- `AppModel` 只处理选择、输入和显示；不启动或持有 Pi 进程。
- `WorkspaceModel` 的项目和线程来自 Server。Telegram 也通过相同的模型提交原生命令，不再扫描 JSONL 决定运行目标。
- `T3DesktopClient` 读取原生 shell/thread HTTP 快照，通过原生命令创建项目/线程、发送、取消和修改模型。当前桌面用 250ms（运行中）/1000ms（空闲）快照轮询，而非 WebSocket 订阅；iOS 仍使用上游订阅。
- `T3BridgeService` 只监督本机 Server。Server 随应用启动；关闭局域网访问不会关闭本机 Server 或取消任务。stdin/stdout 只用于生命周期/就绪，不承载桌面工作区命令。
- `native.mjs` 只提供宿主能力和访问策略，**不替换**原生 OrchestrationLayer、事件存储、投影或 reactors。
- `pi-provider.mjs` 是实际 ProviderDriver/ProviderAdapter；`pi-rpc.mjs` 是其私有 JSONL 传输，不是第二套客户端 API。
- 已删除 DesktopBridge、桌面反向投影、私有 workspace IPC、移动线程路径绑定、独立 command receipts 和旧桥接鉴权入口。HTTP/RPC 共用 T3 自己的持久化回执。

## 运行与安全边界

Pi runtime 使用 Server 的私有 `pi-sessions/<instance-hash>` 目录；线程映射为稳定 Pi session ID，Provider 实例互相隔离。不使用 `--continue`，不隐式接管旧桌面 JSONL。

并发相同 session start 合并，运行中第二个 turn 拒绝。请求有界、LF/UTF-8 分帧、背压和超时；stderr 只排空，不输出秘密。`agent_end` 不代表完成，`agent_settled` 才终结 T3 turn；中断投影为 aborted。未知提交结果不会自动重发 prompt。Pi 子进程不继承 `PIMAC_T3_*` 管理凭据。

桌面通过私有 supervisor 获取标准 T3 本机客户端凭据；原生 Server 处理读取与命令授权。局域网暴露需要单独明确同意，不监听通配、公网或任意 DNS 地址。配对、授权和撤销使用上游 AuthService。

## 历史与尚未支持的能力

- 状态使用 `server-owned/`，不与旧兼容目录混写。保留原始历史文件，不自动导入、激活或双写旧会话。旧 Telegram 文件路径绑定不会获得新线程写权限。
- 当前支持显式 `full-access`、`default`、文字、模型/思考级别、取消及最多 8 张 PNG/JPEG/WebP 图片（总计 8MiB）。图片先由 T3 存储，再由 Adapter 安全读取。
- 审批/sandbox、plan、回滚、手动压缩、text-generation、扩展交互对话、账户切换和 Fast mode 未实现，不能绕过 Server 降级为桌面 Pi RPC。
- 桌面 Pi steering/follow-up 队列不再提供；运行时显示不可继续发送，完成后才能发下一条。
- 历史导入、完整历史分页、生成图片的富内容呈现以及物理 iPhone/App Store、真实账号/模型验收仍待完成。

## 精简验证

```sh
./scripts/prepare-t3-server.sh
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
swift test
```

旧兼容后端、进程池和反向投影测试已删除。重点保留真实打包 T3 Server + 协议 Pi fixture 的端到端测试，以及 Adapter 所有权、settlement、未知结果 deadline、实例隔离和 OAuth 策略测试；不访问真实模型或账号。

架构切换完成后统一执行测试，不用已退役链路的测试结果证明新链路可用。自动化结果不代表实际 iPhone、Apple 登录或 APNs 已验收。
