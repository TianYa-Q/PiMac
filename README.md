# Pi Mac

[![Release](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml/badge.svg)](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml)
[![GitHub Release](https://img.shields.io/github/v/release/TianYa-Q/PiMac?display_name=tag)](https://github.com/TianYa-Q/PiMac/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://github.com/TianYa-Q/PiMac)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

一个使用 SwiftUI 构建的原生 macOS [Pi coding agent](https://github.com/badlogic/pi-mono) 客户端。它不是终端模拟器，而是通过 Pi 官方 JSONL RPC 协议管理真实的 Agent 会话，并继续使用你已有的 Pi 配置。

![Pi Mac 主界面](docs/images/pi-mac-overview-new.png)

## 功能特性

- 在同一窗口添加和切换多个项目，分别保留会话与后台任务
- 流式显示回答、思考过程和工具调用
- 发送消息、重新编辑历史提问、工作中插入指令和停止任务
- 拖放、选择或粘贴图片与文件，并通过 RPC 发送图片内容
- 切换模型与思考等级
- 多个会话使用独立 RPC 进程在后台并行运行
- 新建、命名和打开持久化会话，重启后自动恢复最近会话
- 查看上下文压缩、Token、费用和上下文占用统计
- 支持 Pi 扩展提供的选择、确认、输入和编辑对话框
- 直接复用 `~/.pi/agent` 中已有的登录、模型、Skills、扩展与配置

## 下载与安装

1. 从 [GitHub Releases](https://github.com/TianYa-Q/PiMac/releases/latest) 下载最新的 `Pi-Mac-vX.Y.Z.zip`。
2. 解压后，将 **Pi Mac.app** 移入“应用程序”目录。
3. 确保已经安装并登录 Pi，然后启动 Pi Mac。

> 当前 Release 使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 首次拦截时，请在 Finder 中右键应用并选择“打开”，或前往“系统设置 → 隐私与安全性”确认打开。

## 环境要求

- macOS 14 或更高版本
- 已安装并登录 [Pi coding agent](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent)

Pi Mac 默认依次查找：

1. `~/Library/pnpm/bin/pi`
2. `/opt/homebrew/bin/pi`
3. `/usr/local/bin/pi`

你也可以在应用设置中指定其他路径。应用通过登录 Shell 启动 Pi，因此在 GUI 环境中仍可读取 Node 和 pnpm 的路径。项目列表及最后使用的项目保存在 macOS `UserDefaults` 中，对话则由 Pi 持久化到 `~/.pi/agent/sessions/`。

## 本地开发

需要 Swift 5.10 或更高版本。克隆仓库后运行：

```bash
git clone https://github.com/TianYa-Q/PiMac.git
cd PiMac
swift run PiMac
```

安装完整 Xcode 后，也可以直接打开 `Package.swift`。

### 检查与测试

项目使用 Swift 工具链自带的 `swift format`，无需额外安装 SwiftLint：

```bash
./scripts/lint.sh
swift build
swift test
```

### 打包应用

```bash
APP_VERSION=0.1.0 BUILD_NUMBER=1 ./scripts/package-app.sh
open "dist/Pi Mac.app"
```

脚本会生成 ad-hoc 签名的 `dist/Pi Mac.app`。公开分发若需避免 Gatekeeper 提示，应改用 Apple Developer 证书签名并完成公证。

## 发布新版本

推送符合 `vX.Y.Z` 格式的标签后，[Release workflow](.github/workflows/release.yml) 会自动运行测试、构建应用、生成 ZIP 和 SHA-256 校验文件，并创建 GitHub Release：

```bash
git tag v0.1.0
git push origin v0.1.0
```

也可以在 GitHub 的 **Actions → Release → Run workflow** 中输入版本标签手动发布。

## License

[MIT](LICENSE)
