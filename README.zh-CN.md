# Pi Mac

[English](README.md) | **简体中文**

[![Release](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml/badge.svg)](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml)
[![GitHub Release](https://img.shields.io/github/v/release/TianYa-Q/PiMac?display_name=tag)](https://github.com/TianYa-Q/PiMac/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://github.com/TianYa-Q/PiMac)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

一个使用 SwiftUI 构建的原生 macOS [Pi coding agent](https://github.com/badlogic/pi-mono) 客户端。它不是终端模拟器，而是通过 Pi 官方 JSONL RPC 协议管理真实的 Agent 会话，并继续使用你已有的 Pi 配置。

![Pi Mac 主界面](docs/images/pi-mac-overview-new.png)

## 功能特性

- 在同一窗口添加和切换多个项目，分别保留会话与后台任务
- 流式显示回答、思考过程和工具调用
- 发送消息、重新编辑历史提问、在工具调用后插入指令、任务完成后继续消息，以及删除尚未消费的排队消息
- 拖放、选择或粘贴图片与文件，并通过 RPC 发送图片内容
- 切换模型与思考等级
- 在设置中检查 Pi 与扩展包版本，并一键更新可用的新版本
- 多个会话使用独立 RPC 进程在后台并行运行
- 新建、命名和打开持久化会话，重启后自动恢复最近会话
- 查看上下文压缩、Token、费用和上下文占用统计
- 支持 Pi 扩展提供的选择、确认、输入和编辑对话框
- 配合 [account-usage](https://github.com/TianYa-Q/account-usage) 管理 Codex 多账户并显示 Codex/Gemini 额度
- 使用 Codex 时，当前账户 5h 剩余额度低于 5% 会自动切换到按账户名顺序的下一个高于 5% 的账户（末尾循环）。跳过隐藏、额度未知或报错的账户；执行中会先暂停等待队列并停止当前运行，确认切换成功后在原 session 中自动继续，保留上下文和排队消息。手动停止会取消自动继续，切换失败则停止自动续跑并将暂存消息恢复到输入框；无可用账户则保持不变。根据扩展额度更新检查，不额外轮询。
- 直接复用 `~/.pi/agent` 中已有的登录、模型、Skills、扩展与配置

## 下载与安装

1. 从 [GitHub Releases](https://github.com/TianYa-Q/PiMac/releases/latest) 下载最新的 `Pi-Mac-vX.Y.Z.zip`。
2. 解压后，将 **Pi Mac.app** 移入“应用程序”目录。
3. 确保已经安装并登录 Pi。
4. 如需账户管理与额度显示，安装 `account-usage` 扩展，然后启动 Pi Mac：

   ```bash
   pi install git:github.com/TianYa-Q/account-usage@v1.0.0
   ```

> 当前 Release 使用 ad-hoc 签名，尚未经过 Apple 公证。macOS 首次拦截时，请在 Finder 中右键应用并选择“打开”，或前往“系统设置 → 隐私与安全性”确认打开。

## 环境要求

- macOS 14 或更高版本
- 已安装并登录 [Pi coding agent](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent)

Pi Mac 默认依次查找：

1. `~/Library/pnpm/bin/pi`
2. `/opt/homebrew/bin/pi`
3. `/usr/local/bin/pi`

你也可以在应用设置中指定其他路径。应用通过登录 Shell 启动 Pi，因此在 GUI 环境中仍可读取 Node 和 pnpm 的路径。项目列表及最后使用的项目保存在 macOS `UserDefaults` 中，对话则由 Pi 持久化到 `~/.pi/agent/sessions/`。

## Telegram 远程控制

1. 在 Telegram 中通过官方 `@BotFather` 创建专属 Bot，复制 Token。
2. 在 Pi Mac 的「设置 → Telegram 远程控制」填写 Token 和你自己的 Telegram **数字用户 ID**（不是用户名），勾选启用并点击「保存并应用」。Token 以明文保存在本机应用设置（`UserDefaults`）中，不会触发钥匙串授权。旧版钥匙串 Token 不会自动读取或删除，升级后请重新填写；如需清理旧凭据，可在「钥匙串访问」中手动删除 `PiMac.Telegram`。
3. 与 Bot 私聊，输入 `/` 即可看到已注册的命令补全（连接成功后生效）；也可发送 `/help` 或点击消息下方按钮。用 `/projects` 下方的按钮切换 Telegram 专用项目，确认 `/status` 就绪后直接发送文本或照片（可附说明文字）执行任务，完成后自动回传文本回复。项目较多时可点击「下一页」查看其余项目。

`/status` 会显示 Telegram 会话的当前 Codex 账户、模型、推理强度和上下文占比（尚无统计时显示“待统计”）；使用 `/model` 和 `/thinking` 下方按钮分别选择模型和推理强度。Telegram 的选择保存在独立设置中，不会修改桌面的模型和推理强度；仅在会话空闲且就绪时可更改。

使用 `/sessions` 查看本次运行已打开的 Telegram 会话（执行中或有排队任务的优先），列表显示项目、会话名称和排队数量，点击按钮即可切换后续消息的目标，不中断其他任务，也不改变桌面选择。列表支持分页；旧按钮失效时重新发送 `/sessions`。目前每个项目对应一个 Telegram 会话，不包含桌面会话。

其他命令：`/usage` 或 `/accounts` 查看 account-usage 扩展同步的 Codex/Gemini 各账户剩余额度（使用最近一次缓存，不主动刷新），点击额度消息下方的账户按钮可切换 Telegram 会话的 Codex 账户（不会修改桌面会话，空闲且就绪时可切换）、`/new` 新建会话并直接返回状态、`/compact` 在会话空闲且无排队任务时压缩上下文、`/stop` 停止当前任务并取消等待队列、`/last` 领取自动回传失败的回复（已发送的不重复返回）。Telegram 的项目选择和各项目会话与桌面选择独立：切换项目不会切换 Mac 界面，也不会向桌面当前会话发送任务；重新启动后恢复 Telegram 自己的项目及会话。已经提交的任务回复仍来自原会话。忙碌时新消息会进入内存中的等待队列，上一条结束后按顺序执行；软件退出会清空未执行的队列。扩展确认对话框仍需在 Mac 上处理。

- 默认关闭，仅接受配置用户的私聊，忽略群聊、其他用户和本次连接启动前的消息。
- Mac 必须保持唤醒、联网并运行 Pi Mac；使用 Telegram 长轮询，不需要开放入站端口。同一个 Bot 不应被其他程序轮询，也不能配置 Webhook。
- 远程任务拥有本机 Pi 的文件访问及命令执行权限，任务与回复会经过 Telegram（Bot 私聊不是端到端加密）。请保护好 Telegram 账户及 Token，不要使用共享 Bot。
- 网络故障时自动重连；回复发送失败可用 `/last` 获取。关闭开关并保存即可停止控制，清空 Token 后保存可删除本地设置中的 Token（不会删除旧版钥匙串条目）。

## 本地开发

需要 Swift 5.10 或更高版本。克隆仓库后运行：

```bash
git clone https://github.com/TianYa-Q/PiMac.git
cd PiMac
swift run PiMac
```

开发时可改用 `python3 scripts/dev.py`：监听 Swift 源文件并自动构建，成功构建后等待桌面及 Telegram 会话全部空闲、没有排队消息或扩展确认，再自动重启 Pi Mac。构建失败不会重启；Ctrl-C 仅停止监听。普通运行与打包应用不会自动重启。

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

脚本默认生成 ad-hoc 签名的 `dist/Pi Mac.app`。Telegram Token 保存在本机应用设置中，重新打包不会触发钥匙串授权。如需使用固定的代码签名证书，可设置：

```bash
CODE_SIGN_IDENTITY="证书名称或 SHA-1" ./scripts/package-app.sh
```

公开分发若需避免 Gatekeeper 提示，应使用 Apple Developer 证书签名并完成公证。

## 发布新版本

推送符合 `vX.Y.Z` 格式的标签后，[Release workflow](.github/workflows/release.yml) 会自动运行测试、构建应用、生成 ZIP 和 SHA-256 校验文件，并创建 GitHub Release：

```bash
git tag v0.1.0
git push origin v0.1.0
```

也可以在 GitHub 的 **Actions → Release → Run workflow** 中输入版本标签手动发布。

## License

[MIT](LICENSE)
