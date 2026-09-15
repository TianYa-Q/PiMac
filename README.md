# Pi Mac

使用 SwiftUI 编写的原生 macOS Pi 客户端。界面不是终端模拟器，而是通过 Pi 官方 JSONL RPC 协议管理真实 Agent 会话。

## 已实现

- 选择任意项目目录并启动 Pi
- 流式显示回答、思考过程和工具调用
- 发送消息、工作中插入指令、停止任务
- 切换模型和思考等级
- Codex Desktop 式单窗口会话切换；多个会话使用独立 RPC 进程在后台并行运行
- 新建、命名、打开持久化会话，重启后自动继续项目最近一次会话
- 上下文压缩、Token/费用/上下文占用统计
- Pi 扩展的选择、确认、输入和编辑对话框
- 继续使用 `~/.pi/agent` 中已有的登录、模型、Skills、扩展和配置

## 环境

- macOS 14+
- Swift 5.10+
- 已安装并登录 Pi

默认寻找以下 Pi 路径：

1. `~/Library/pnpm/bin/pi`
2. `/opt/homebrew/bin/pi`
3. `/usr/local/bin/pi`

也可以在应用的“设置”中修改。程序通过登录 shell 启动 Pi，因此 GUI 环境下仍能找到 Node/pnpm。最后使用的项目目录会保存在 macOS `UserDefaults` 中，下次启动自动重新连接；对话由 Pi 持久化在 `~/.pi/agent/sessions/`。

## 开发运行

```bash
cd /Users/tianya/localDocument/program/PiMac
swift run PiMac
```

也可以在安装完整 Xcode 后双击 `Package.swift` 开发。

## 代码检查

项目使用 Swift 工具链自带的 `swift format` 同时进行格式和基础 lint 检查，无需额外安装 SwiftLint：

```bash
./scripts/lint.sh
swift build
```

## 生成 `.app`

```bash
cd /Users/tianya/localDocument/program/PiMac
chmod +x scripts/package-app.sh
./scripts/package-app.sh
open "dist/Pi Mac.app"
```

脚本会生成 ad-hoc 签名的 `dist/Pi Mac.app`。如需分发给其他 Mac，需要使用 Apple Developer 证书签名并公证。

## 测试

```bash
swift test
```
