# Pi Mac

**English** | [简体中文](README.zh-CN.md)

[![Release](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml/badge.svg)](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml)
[![GitHub Release](https://img.shields.io/github/v/release/TianYa-Q/PiMac?display_name=tag)](https://github.com/TianYa-Q/PiMac/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://github.com/TianYa-Q/PiMac)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A native macOS workspace for the [Pi coding agent](https://github.com/earendil-works/pi), built with SwiftUI. Work across projects, follow agent conversations, and review code changes without living in a terminal.

PiMac uses the official [T3 Server](https://github.com/pingdotgg/t3code) orchestrator V2 and its built-in Pi Provider. The Server owns projects, threads, queues, and persistence; PiMac provides the native interface and Mac integration. Upstream providers, models, tools, and delegation capabilities are not restricted by a PiMac-specific allowlist.

> This README describes the **current source**, not feature parity with every published release. The project is actively evolving; historical-session upgrades and physical-device iOS compatibility still need acceptance testing. See [architecture and limitations](docs/t3-server-migration.md).

![PiMac native conversation interface with a project sidebar and Markdown response](docs/images/pi-mac-overview-new.png)

*Current SwiftUI views rendered with local sample data in an isolated capture window. No real conversations or accounts are shown; the Server is intentionally offline. Interface labels currently include Chinese.*

## Highlights

- **Projects and conversations** — switch projects, search sessions, follow parent/child task relationships, and distinguish running tasks from unread completions.
- **Agent workflow** — stream replies and reasoning, inspect tool calls, attach files and images, steer a task, queue follow-ups, cancel work, and request context compaction.
- **Models and context** — select available models and thinking levels, configure model visibility and context limits, and view available token/context telemetry. Missing metrics are not presented as measured results.
- **Native Git** — inspect branches, changed files, and searchable diffs; review selected files before committing, pushing, pulling, or creating a PR. See [Git workflows](docs/t3-code-integration.md#git--vcs).
- **Account management** — manage supported ChatGPT/Codex accounts and query quotas independently of conversations. The optional companion extension applies session credentials and performs safe rotation; it does not own the account-management UI. See [account ownership and setup](extensions/account-usage/README.md).
- **Connected workflows** — manage Server scheduled tasks, control conversations through Telegram, or connect a compatible T3 iOS client through LAN/T3 Connect.
- **Mac integration** — native extension dialogs, completion notifications, and optional plugged-in closed-lid operation. See [closed-lid setup and safety](docs/lid-sleep.md).

## Get started

### Requirements

- macOS 14 or later.
- Pi installed and authenticated; the documented compatibility baseline is **1.0.0**. See [Pi compatibility](docs/pi-1.0-compatibility.md).
- Node.js **24+** for the bundled T3 Server.

### Install

1. Download `Pi-Mac-vX.Y.Z.zip` from [GitHub Releases](https://github.com/TianYa-Q/PiMac/releases/latest).
2. Extract it and move **Pi Mac.app** to Applications.
3. Install/authenticate Pi using its [upstream instructions](https://github.com/earendil-works/pi). In PiMac, check the Pi executable path in Settings if it is not discovered automatically.
4. Open a project, choose an available model, and send a message.

> Releases currently use ad-hoc signing and are not notarized by Apple. If macOS blocks first launch, right-click the app in Finder and choose **Open**, or review the block in **System Settings → Privacy & Security**. Only run downloads you trust.

### Optional account session adapter

For managed session credentials and safe account rotation, install `account-usage` from a source checkout:

```sh
npm --prefix extensions/account-usage ci --ignore-scripts
./scripts/link-account-usage.sh
```

Avoid duplicate old installations. Existing runtimes must safely reopen/reload the extension after active work finishes. Private account data stays under `~/.pi/agent` (or `PI_CODING_AGENT_DIR`), never in this repository. The old Pi `/usage` command and `/accounts` management menu are removed; Telegram `/usage` is separate. Read the [extension guide](extensions/account-usage/README.md) before enabling rotation or background activation: activation makes real requests and can consume subscription quota.

## Remote access

### Telegram

Create a bot with Telegram's `@BotFather`. In **Settings → Telegram 远程控制**, enter its token and your numeric Telegram user ID, enable remote control, then save. Use `/help`, `/projects`, `/sessions`, `/model`, `/status`, and `/stop` in your private bot chat. Text, images, and documents can be routed to conversations; some extension dialogs still require local interaction.

Keep the Mac awake, online, and PiMac running. Remote control is off by default and accepts only the configured user's private messages. The bot token and pending delivery data are stored unencrypted in local app preferences. Bot chats are not end-to-end encrypted, and remote tasks have the same local execution permissions as desktop tasks. A failed acknowledgement can lead to duplicate Telegram delivery; do not treat messaging as an exactly-once channel.

### T3 iOS / T3 Connect

Open **Settings → T3 iOS 连接** for LAN pairing or official T3 Connect. Both share the same Server and environment. LAN defaults on and uses unencrypted HTTP: use a trusted network and do not forward the port publicly. T3 Connect uses an authenticated Cloudflare Tunnel, not end-to-end encryption. A protocol-2-compatible phone client is required; installed App Store builds, Apple sign-in, and APNs still need physical-device validation. See [connection instructions and security boundaries](docs/t3-code-integration.md).

## Current boundaries

- Tool presentation follows the official V2 protocol; arbitrary terminal widgets and the former private rich-output pipeline are not restored. Supported tool images and local Markdown image links use validated Server assets.
- The desktop is not a second Pi runtime or session-file writer. Old custom-adapter conversations are **not guaranteed** to resume the identical native runtime after migration.
- Model support and permissions come from upstream. Provider discovery defaults to Pi; this is a configurable discovery preference, not a ban on other upstream providers.
- Do not infer support from old screenshots or historical change notes. For migration details use the [architecture guide](docs/t3-server-migration.md); for account behavior use the [current account guide](extensions/account-usage/README.md).

## Development

Requires Swift 5.10+ and Node.js 24+:

```sh
git clone https://github.com/TianYa-Q/PiMac.git
cd PiMac
./scripts/prepare-t3-server.sh
python3 scripts/dev.py
```

The watcher builds a separate development app and reloads only when activity and edit-batch safety gates permit. **Do not stop/restart it during active work:** stopping the watcher also stops its app and child services. Before multi-step runtime edits, open a batch with `python3 scripts/dev.py --begin-edit --label 'task'`, retain the token, and close only that batch with `--end-edit TOKEN` after validation. See [development reload safety](docs/development-reload.md).

Validation entry points:

```sh
./scripts/lint.sh
swift test --jobs 2 --no-parallel
npm --prefix sidecars/t3-server run check
npm --prefix sidecars/t3-server test
```

Tests run serially, with at most two Swift compilation jobs and two esbuild workers for Server test bundling. Prefer `swift test --jobs 2 --no-parallel --filter SuiteName` for affected suites; do not launch multiple test commands concurrently. Use `./scripts/check.sh` when full validation is needed: it prepares the Server again and is unnecessary for every small edit.

Package locally with `APP_VERSION=0.1.0 BUILD_NUMBER=1 ./scripts/package-app.sh`. Tagged releases (`vX.Y.Z`) use the [release workflow](.github/workflows/release.yml). Apple notarization requires your own Developer ID setup.

## Contributing

Bug reports, documentation fixes, and focused pull requests are welcome. Include your macOS/Pi version, reproduction steps, and whether you use a release or source build. Remove tokens, pairing credentials, private transcripts, and account data from logs and screenshots before sharing.

## License

[MIT](LICENSE)
