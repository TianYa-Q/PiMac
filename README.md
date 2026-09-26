# Pi Mac

**English** | [简体中文](README.zh-CN.md)

[![Release](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml/badge.svg)](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml)
[![GitHub Release](https://img.shields.io/github/v/release/TianYa-Q/PiMac?display_name=tag)](https://github.com/TianYa-Q/PiMac/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://github.com/TianYa-Q/PiMac)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A native macOS [Pi coding agent](https://github.com/badlogic/pi-mono) client built with SwiftUI. Rather than emulating a terminal, Pi Mac manages real agent sessions through Pi's official JSONL RPC protocol and continues to use your existing Pi configuration.

![Pi Mac overview](docs/images/pi-mac-overview-new.png)

## Features

- Add and switch between multiple projects in one window, with separate sessions and background tasks
- Stream responses, reasoning, and tool calls
- Send messages, re-edit previous prompts, steer after tool calls, follow up after completion, and remove queued messages that have not been consumed
- Attach images and files by dragging, selecting, or pasting, and send image content over RPC
- Switch models and thinking levels
- Check Pi and extension package versions in Settings, then install available updates with one click
- Run multiple sessions concurrently in independent background RPC processes
- Create, name, and open persistent sessions, and automatically restore the most recent session after relaunching
- View compaction, token, cost, and context usage statistics
- Support select, confirm, input, and editor dialogs provided by Pi extensions
- Manage multiple Codex accounts and display Codex/Gemini quotas with [account-usage](https://github.com/TianYa-Q/account-usage)
- Reuse existing authentication, models, skills, extensions, and settings from `~/.pi/agent`

## Download and Installation

1. Download the latest `Pi-Mac-vX.Y.Z.zip` from [GitHub Releases](https://github.com/TianYa-Q/PiMac/releases/latest).
2. Extract the archive and move **Pi Mac.app** to your Applications folder.
3. Make sure Pi is installed and you are signed in.
4. To enable account management and quota display, install the `account-usage` extension before launching Pi Mac:

   ```bash
   pi install git:github.com/TianYa-Q/account-usage@v1.0.0
   ```

> Current releases use ad-hoc signing and are not notarized by Apple. If macOS blocks the app the first time, right-click it in Finder and choose **Open**, or allow it under **System Settings → Privacy & Security**.

## Requirements

- macOS 14 or later
- [Pi coding agent](https://github.com/badlogic/pi-mono/tree/main/packages/coding-agent), installed and authenticated

Pi Mac searches for the Pi executable in this order by default:

1. `~/Library/pnpm/bin/pi`
2. `/opt/homebrew/bin/pi`
3. `/usr/local/bin/pi`

You can also select another path in the app's settings. Pi is launched through a login shell so paths for Node and pnpm remain available in a GUI environment. The project list and most recently used project are stored in macOS `UserDefaults`; conversations are persisted by Pi under `~/.pi/agent/sessions/`.

## Telegram Remote Control

Create a dedicated bot with Telegram's official `@BotFather`. In **Settings → Telegram 远程控制**, enter its token and your numeric Telegram user ID (not your username), enable it, and click **保存并应用**. The token is stored unencrypted in local app preferences (`UserDefaults`), without Keychain prompts. Existing Keychain tokens are not read or removed: re-enter your token after upgrading, and delete the old `PiMac.Telegram` item manually in Keychain Access if desired.

Use `/sessions` to list Telegram sessions opened during this app run, with running or queued sessions first. Each entry shows its project, session title, and queue count. Click a session button to redirect subsequent messages without stopping other tasks or changing the desktop selection. The list is paginated; request `/sessions` again if an old button expires. Currently each project has one Telegram session; desktop sessions are not included.

In a private chat with your bot, type `/` to see registered command suggestions after the bot connects, or send `/help`. Use the inline buttons or `/projects`, `/status`, `/model`, `/thinking`, `/usage`, `/accounts`, `/new`, `/compact`, `/stop`, and `/last`. `/status` shows Telegram's current Codex account, model, reasoning level, and context usage percentage; choose them using the buttons under `/model` and `/thinking` while the session is idle. Telegram stores these selections separately from the desktop. `/usage` or `/accounts` shows the latest cached Codex/Gemini account quotas from the account-usage extension without triggering a refresh. Use the account buttons below the quota message to switch the Telegram session's Codex account while idle and ready, independently of the desktop session. Use the project buttons under `/projects` to switch projects; use Next to browse more projects. Send text or a photo (optionally with a caption) to run a task in Telegram's own session; the completed text reply is sent back automatically. Telegram's project selection and per-project sessions are independent of the Mac UI selection and are restored on relaunch. Only undelivered replies can be retrieved with `/last`; already delivered replies are not repeated. Pending replies remain attached to their original session. Messages sent while the session is busy enter an in-memory FIFO queue and run after the current task finishes. `/compact` compresses the current session when idle with no queued tasks; `/stop` cancels pending messages. Unstarted queued messages are discarded when the app exits. Extension dialogs still require local interaction.

Remote control is off by default and only accepts the configured user's private messages. Messages from before the current connection started are ignored. Keep the Mac awake, online, and Pi Mac running. Long polling requires no inbound ports; do not use the same bot with another polling client or a webhook. Failed replies can be retrieved with `/last`.

**Security:** Remote tasks have the same filesystem and command-execution permissions as local Pi. Prompts and replies pass through Telegram; bot chats are not end-to-end encrypted. Protect your account and token. Disable and save to stop control; clear the token and save to remove it from local preferences (this does not delete the old Keychain item).

## Local Development

Swift 5.10 or later is required. Clone the repository and run:

```bash
git clone https://github.com/TianYa-Q/PiMac.git
cd PiMac
swift run PiMac
```

For development, run `python3 scripts/dev.py` instead: it rebuilds on Swift source changes and relaunches Pi Mac after a successful build once all desktop and Telegram sessions are idle, with no queued prompts or extension dialogs. Failed builds do not restart the app. Ctrl-C stops watching but leaves the app running. Normal and packaged runs do not auto-restart.

With the full Xcode installation, you can also open `Package.swift` directly.

### Checks and Tests

The project uses `swift format` included with the Swift toolchain, so SwiftLint is not required:

```bash
./scripts/lint.sh
swift build
swift test
```

### Packaging the App

```bash
APP_VERSION=0.1.0 BUILD_NUMBER=1 ./scripts/package-app.sh
open "dist/Pi Mac.app"
```

The script creates an ad-hoc-signed app at `dist/Pi Mac.app` by default. Telegram tokens are stored in local preferences, so repackaging does not prompt for Keychain access. To use a consistent code-signing certificate, set:

```bash
CODE_SIGN_IDENTITY="certificate name or SHA-1" ./scripts/package-app.sh
```

For public distribution without Gatekeeper warnings, use an Apple Developer certificate and notarize the app.

## Publishing a Release

Push a tag in the `vX.Y.Z` format. The [Release workflow](.github/workflows/release.yml) will run tests, build the app, generate a ZIP archive and SHA-256 checksum, and create a GitHub Release automatically:

```bash
git tag v0.1.0
git push origin v0.1.0
```

Alternatively, open **Actions → Release → Run workflow** on GitHub and enter a release tag manually.

## License

[MIT](LICENSE)
