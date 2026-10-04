# Pi Mac

**English** | [简体中文](README.zh-CN.md)

[![Release](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml/badge.svg)](https://github.com/TianYa-Q/PiMac/actions/workflows/release.yml)
[![GitHub Release](https://img.shields.io/github/v/release/TianYa-Q/PiMac?display_name=tag)](https://github.com/TianYa-Q/PiMac/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-000000?logo=apple)](https://github.com/TianYa-Q/PiMac)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A native macOS [Pi coding agent](https://github.com/earendil-works/pi) client built with SwiftUI. Desktop, iOS and Telegram use official T3 Server orchestrator V2 and its built-in Pi Provider; the custom Pi Adapter has been removed.

> **Source architecture update:** migrated to the official main Pi Provider and orchestration protocol 2. Native extension dialogs, /compact and steering are supported; private account status, Fast/compaction-model overrides and rich tool output are no longer provided. Release-era descriptions below are not feature-parity claims. Real historical upgrades and mobile acceptance remain pending. See [current architecture and limits](docs/t3-server-migration.md).

![Pi Mac overview](docs/images/pi-mac-overview-new.png)

## Features

- LAN transport hardening, live pairing expiry, offline-device revocation and actionable extension health diagnostics: see [connection and quota hardening](docs/connection-quota-hardening.md).

- Scheduler adds remembered sorting, running-state filters and configuration checks before actions; the extension adds sample-age warnings and non-blocking stream cleanup. See [scheduler and stream hardening](docs/scheduler-stream-hardening.md).
- Add and switch between multiple projects in one window, with separate sessions and background tasks
- Session search adds `title:` / `text:` scopes, scoped exclusions, quick-insert controls and retry after Server read failures. The extension adds count-only `/usage doctor json`, allowlisted error diagnostics and cancellation-preserving HTTP reads. See [search and diagnostic improvements](docs/search-diagnostics-improvements.md).
- Current source adds native T3 Git controls: branches, searchable/sortable changes with selected/unselected filters, bounded, syntax-colored diffs with line numbers, search (⌘F), change-only filtering and copy, selected-file commits, push, PR creation and pull; a resizable sidebar with remembered width, a compact Server badge beside Pi Mac, and Git beside the composer’s compact control without a conversation header. See [Git integration](docs/t3-code-integration.md#git--vcs).
- Git safety adds searchable local branches and a full operation review (branch, commit message and selected files). Refreshing expires old confirmations; the mutation stays locked through status reconciliation. The extension adds read-only `/usage doctor` and identity-aware quota caches. See [this optimization round](docs/git-account-safety-round.md).
- Manage Server-owned scheduled tasks with multi-keyword search, state filters, refresh timestamps and paused copies. Unknown mutation outcomes require an explicit successful refresh; copies never reuse a thread binding or worktree. See [reliability improvements](docs/reliability-improvements.md).
- Tool text details add bounded head/tail previews, literal search/navigation with case-sensitive and whole-word options, line wrapping, full copying and export. Search state is cached across navigation; extension cache locks use cancellable 15-second contention budgets and safe late-lease cleanup. This does not restore rich output stripped by official V2. See [output search and lock reliability](docs/output-search-lock-reliability.md) and [preview and refresh hardening](docs/tool-preview-cache-hardening.md).
- Stream responses, reasoning, and tool calls
- Support Pi 1.0 Code Mode: show JavaScript, nested calls and image tool results; retain existing Pi tool/MCP settings
- Send messages, re-edit previous prompts, steer after tool calls, follow up after completion, and remove queued messages that have not been consumed
- Attach images and files by dragging, selecting, or pasting, and send image content over RPC
- Switch models and thinking levels
- Check Pi and extension package versions in Settings, then install available updates with one click
- Reuse an idle Pi RPC process when switching saved sessions, even across projects; run concurrent tasks in separate processes and stop inactive processes while retaining their saved conversations
- Create, name, and open persistent sessions; on relaunch, reopen the current project's most recently active conversation if you sent a message or received a text reply within the past 30 minutes, otherwise start a new session; when switching projects, reopen the last selected conversation only if it was active within the past 30 minutes, otherwise start a new session
- Usage totals include assistant responses, nested model work in tools, compaction/branch summaries, and standalone usage entries; old indexes rebuild automatically. Nested tool calls stay under their parent and restore from session metadata
- RPC respects handled inputs, bounds inspection request deadlines, cancels pending requests on stop/restart, and writes without blocking the UI
- View compaction, token, cost, and context usage statistics, plus task output speed in tokens/s using actual provider usage (includes reasoning and request latency, excludes tool time; updates at response completion when streaming usage is unavailable)
- Toggle OpenAI Responses / Codex Fast mode for priority processing (may consume more quota; does not change reasoning level). Preferences survive restarts and are shared by desktop and Telegram without modifying global Pi settings
- Support select, confirm, input, and editor dialogs provided by Pi extensions
- Native extension dialogs add searchable choices, project/session context and waiting-request counts. Presentation-scoped responses reject stale callbacks; bounded queues and hardened private account JSON prevent runaway requests and unsafe local reads. See [dialog and storage hardening](docs/extension-dialog-storage-hardening.md).
- Account cards show actual quota sample age, stale/clock-skew warnings and refresh progress. Account management supports search (more than four accounts) and a read-only Health Check; expired dialogs cannot act on a replacement session/provider. See [snapshot and lifecycle hardening](docs/account-snapshot-lifecycle.md).
- Manage OpenAI ChatGPT / Codex accounts and Gemini quotas with the companion [account-usage](extensions/account-usage/README.md), maintained in this repository. Credentials, defaults and quotas stay provider-isolated; API keys are never automatically replaced. Low-quota rotation and weekly-budget balancing run inside the extension at safe Pi boundaries, independent of the desktop UI; automatic changes affect only the current session
- Reuse existing authentication, models, skills, extensions, and settings from `~/.pi/agent`

## Download and Installation

1. Download the latest `Pi-Mac-vX.Y.Z.zip` from [GitHub Releases](https://github.com/TianYa-Q/PiMac/releases/latest).
2. Extract the archive and move **Pi Mac.app** to your Applications folder.
3. Make sure Pi is installed and you are signed in.
4. Install the companion `account-usage` from this repository (new OpenAI support requires Pi 0.99.1+):

   ```bash
   npm --prefix extensions/account-usage ci --ignore-scripts
   ./scripts/link-account-usage.sh
   ```

   Back up/remove an old installation first to avoid duplicate loading. Select an `openai` model and use `/accounts` to log in to ChatGPT; legacy tokens are not migrated. Account data remains under `~/.pi/agent`, never in the repository. Restart Pi / reconnect sessions after updates. Run `./scripts/check.sh` for full validation.

> Current releases use ad-hoc signing and are not notarized by Apple. If macOS blocks the app the first time, right-click it in Finder and choose **Open**, or allow it under **System Settings → Privacy & Security**.

## Requirements

- macOS 14 or later
- [Pi coding agent](https://github.com/earendil-works/pi/tree/main/packages/coding-agent), installed and authenticated; compatibility tested with **1.0.0**
- Node.js 24+ (bundled T3 Server requirement)

Pi Mac searches for the Pi executable in this order by default:

1. `~/Library/pnpm/bin/pi`
2. `/opt/homebrew/bin/pi`
3. `/usr/local/bin/pi`

You can also select another path in the app's settings. Pi is launched through a login shell so paths for Node and pnpm remain available in a GUI environment. The project list and most recently used project are stored in macOS `UserDefaults`; conversations are persisted by Pi under `~/.pi/agent/sessions/`.

## Code Mode

Enable the official tool alongside your existing tools in `~/.pi/agent/settings.json`:

```json
{"defaultTools": ["+codemode"], "codemode": {"mode": "on"}}
```

Merge these fields into your settings; do not replace the file or a custom tool list.
From a source checkout, `node scripts/enable-codemode.mjs` preserves selections and
backs up the original file. Reconnect idle sessions after changing it. Trusted
project settings may override the selection. See [Pi 1.0 compatibility](docs/pi-1.0-compatibility.md).

## Telegram Remote Control

Create a dedicated bot with Telegram's official `@BotFather`. In **Settings → Telegram 远程控制**, enter its token and your numeric Telegram user ID (not your username), enable it, and click **保存并应用**. The settings page separates live connection status from unsaved changes; saving does not mean the bot is connected. Changing existing credentials or disabling control asks for confirmation before clearing waiting tasks. Credential changes also clear undelivered messages and reply-to-session links; disabling preserves undelivered messages for retry on re-enable. The token is stored unencrypted in local app preferences (`UserDefaults`), without Keychain prompts. Existing Keychain tokens are not read or removed: re-enter your token after upgrading, and delete the old `PiMac.Telegram` item manually in Keychain Access if desired.

Use `/sessions` to list the current Telegram project's saved Pi sessions, including sessions from previous app runs. Tap a session to switch subsequent messages to it, or use `/new` to create one. You can also reply to a previous task message, acknowledgement, status card, or bot reply to route only that reply to the message's original project and session without changing the selected project or session. Subsequent unquoted text, photos, and files still use the previously selected destination; only explicit `/projects` or `/sessions` selection changes it. These message links survive app restarts. Switching requires the current session to be idle with no queued messages; sessions from other projects cannot be selected here. The list is paginated; request `/sessions` again if an old button expires. Telegram's selection does not change the desktop selection.

In a private chat with your bot, type `/` to see registered command suggestions after the bot connects, or send `/help`. Use the inline buttons or `/projects`, `/status`, `/model`, `/thinking`, `/usage`, `/new`, `/compact`, and `/stop`. Bot cards use compact titles and consistent fields, bounded names/previews, and short actionable hints for phone screens. Successful AI replies remain unmodified; errors and partial replies are clearly labelled. `/status` or the Status button refreshes the current session details, appending a paginated overview for other projects with running or queued tasks, pending confirmations, ongoing delivery, undelivered results, or connection failures (including desktop and Telegram tasks). Healthy idle projects are omitted and never started by viewing status. Automatic task cards use the same format; there is no separate Refresh button. Partial-quote replies include the selected text alongside your reply, including photo/document captions, without changing original-session routing. Selecting a project shows its current Codex account, model, reasoning level, and context usage percentage; choose them using the buttons under `/model` and `/thinking` while the session is idle. Desktop and Telegram share model, reasoning, and Fast-mode preferences. Opening the same saved conversation on either surface reuses one task runtime; Telegram routing does not change the desktop selection. `/usage` shows the latest cached Codex/Gemini account quotas and account-switching buttons without triggering a refresh. The legacy `/accounts` alias remains compatible with typed commands and old cards, but is omitted from the command menu and help; its navigation emits `/usage`. Codex accounts are paginated 4 per page, with single-line remaining percentages and reset countdowns, low-quota warnings, and cache age (a warning appears after 15 minutes). Gemini quotas appear on the first page. The cache button reads the newest local snapshot only. Status cards highlight high context occupancy (85% or more) and extension confirmations that require interaction on the Mac. Use the account buttons below the quota message to switch the Telegram session's Codex account while idle and ready, with the change applying to that conversation on both surfaces. Use the project buttons under `/projects` to switch projects; use Next to browse more projects. Send text, a photo, or a document up to 20 MB (optionally with a caption) to run a task in Telegram's own session; documents are saved temporarily on the Mac and passed to Pi as local file attachments (send images as photos for image analysis). The completed text reply is sent back automatically. Without adding instructions to Pi's prompt, the bot detects project files created or modified during this task when the final reply explicitly links to them in Markdown (e.g. `[Download](report.pdf)`). Inline code or plain file paths do not trigger uploads. It uploads up to 3 regular files of at most 20 MB each and retries failed uploads in the background. Telegram's project selection and per-project sessions are independent of the Mac UI selection and are restored on relaunch. The two most recently selected projects stay connected for fast switching; cold switches return promptly and refresh the status card automatically when Pi is ready. Failed task replies and command confirmations are queued locally and retried automatically, including after app restarts; changing the bot token or allowed user ID clears these queues. Pending replies remain attached to their original session. Messages sent while the session is busy or not ready enter an in-memory FIFO queue. Editing a queued message's text or attachment caption updates its content without changing its destination or position. When its acknowledgement is available, edit feedback updates that existing card rather than sending another confirmation. The queue acknowledgement includes a button to cancel that single waiting task; other queued and running tasks are unaffected. `/queue` or the Queue button shows the current default session's Telegram waiting tasks, 5 per page, with prompt previews, attachment counts, and wait ages. Cancel buttons use task IDs and refresh the list after cancellation; already-started or expired tasks are not stopped. Viewing the queue never starts or changes a session. Pi's internal queued messages are shown only as a separate count and must be managed on the Mac. Deleting the original Telegram message does not cancel it. Edits never resubmit tasks that have already started or been cancelled; to replace an attachment, cancel and resend. While disconnected or failed, Pi Mac retries connecting every 5 seconds and runs queued tasks when ready without requiring you to resend them. Submitted tasks immediately get an interactive status card with navigation buttons, a waiting-task count, and an elapsed timer refreshed roughly every 30 seconds. Project and model lists show 8 items per page; both use full-width buttons. Navigation uses recognizable icons and short labels, and Stop occupies a separate row with an explicit queue-cancellation label. Project, model, and account buttons use stable identifiers, so list reorderings cannot change what a button selects; removed or ambiguous choices and legacy index buttons require reopening the list. Model and reasoning changes briefly wait for observed settings and distinguish confirmed changes from pending requests. Model, reasoning, and account switching all require an idle, ready session without queued tasks. Session actions are contextual: active tasks show Stop, while idle session pages show New and Compact. Mutation buttons are bound to the session shown when the card was sent: if the selection has changed, or the card is from a previous run or a retried notice, the bot rejects the action without touching another session. Open Status or the relevant list again to get fresh buttons; navigation and per-task queue cancellation remain available. Task acknowledgements show routing, a short prompt preview, attachments, and queue position; waiting for local extension confirmation is called out explicitly. Browse other pages within that card without automatic updates overwriting them; edits are serialized per card and navigation invalidates queued timer edits, so an in-flight timer update cannot land after the newly selected page. Returning to the running session's status resumes the timer from the original start time. Queue acknowledgement cards remove their cancellation buttons when the task is submitted, cancelled, or rejected. Tasks finishing during the initial card send still receive a terminal card with frozen duration and the latest result-delivery state. Completion updates only cards still showing that task's status; the result is still sent separately. Completion cards distinguish successful, aborted, failed, and no-text outcomes, freeze the execution duration before delivery, and show delivery and remaining-queue status separately. Partial output after an abort or provider error is labelled as partial. Completed idle cards show New/Compact instead of Stop; cards for other sessions retain navigation without mutation buttons. `/compact` compresses the current session when idle with no queued tasks; `/stop` cancels pending messages. Unstarted queued messages are discarded when the app exits. Extension dialogs still require local interaction.

Remote control is off by default and only accepts the configured user's private messages. Messages predating the first successful connection are ignored; after the first successful poll, the update cursor is saved so messages received while the app is offline are processed on restart. Changing the bot token or allowed user ID resets the cursor. Updates are checkpointed before dispatch to avoid running remote commands twice after a failed acknowledgement or restart; a crash between checkpointing and dispatch can leave an update unexecuted. Keep the Mac awake, online, and Pi Mac running. Long polling requires no inbound ports; do not use the same bot with another polling client or a webhook. Failed replies are retried automatically.

Delivery checkpoints each acknowledged reply chunk locally, so retries and restarts continue with the remaining chunks. Network failures use exponential backoff (5 seconds up to 5 minutes); rate limits honor Telegram's `retry_after`. Permanent API errors pause delivery while retaining pending results. Fix the configuration and use **重新连接** in Settings to resume without discarding running tasks or waiting queues. Card edits create a replacement only when Telegram confirms the original is missing or uneditable; failed edits retry the same card, and navigation invalidates stale retries. Telegram offers no send idempotency key: if a send succeeds but its acknowledgement is lost, a retry can still duplicate that chunk.

**Security:** Remote tasks have the same filesystem and command-execution permissions as local Pi. Prompts and replies pass through Telegram; bot chats are not end-to-end encrypted. Undelivered replies and command confirmations are stored unencrypted in local app preferences. Protect your account and token. Disable and save to stop control; clear the token and save to remove it from local preferences (this does not delete the old Keychain item).

## T3 Code iOS

**Settings → T3 iOS 连接** offers private-IPv4 LAN HTTP/WebSocket access and official T3 Connect managed Cloudflare Tunnel. LAN starts automatically on an eligible physical interface; manually disabling it is remembered. LAN pairing links/codes are temporary, and LAN HTTP is unencrypted: use trusted networks only. For Tunnel, sign in on Mac and iPhone with the same account. Both transports share the same Server and environment identity; phone catalog behavior and pairing require physical-device acceptance. The desktop Server and administration remain loopback-only.

The official Server owns projects, threads and tasks. Remote access has Pi's local execution permissions; transcripts and attachments traverse Cloudflare, not end-to-end encryption. Pausing activity publication does not close the Tunnel; unlink to revoke it. Settings show bounded, credential-free connection diagnostics. Protocol tests cover HTTPS/TLS termination and WebSocket authentication; real App Store/Apple/APNs acceptance remains a physical-device check. See [connection steps, limitations and recovery](docs/t3-code-integration.md). Restart a new build only after existing tasks finish.

## Local Development

Swift 5.10 or later is required. Clone the repository and run:

```bash
git clone https://github.com/TianYa-Q/PiMac.git
cd PiMac
./scripts/prepare-t3-server.sh
swift run PiMac
```

For development, run `python3 scripts/dev.py` instead: it coalesces source changes and waits until all desktop and Telegram sessions are idle, with no queued prompts or extension dialogs, before building. After a successful build, Pi Mac rechecks idle status before relaunching. Changes during a build defer the reload until a fresh build succeeds. Failed builds do not restart the app. On exit (including Ctrl-C or SIGTERM), the watcher stops this project's Pi Mac instances, T3 Server and child services, including hot-relaunched apps; remaining processes are force-stopped after a short grace period. This interrupts active tasks. A second watcher is refused; if an old app is still running, it is cleaned up on exit before you start the watcher again. Normal and packaged runs do not auto-restart.

The watcher builds and runs `.build/Pi Mac Dev.app`, enabling native notifications with the app icon. Allow notifications on first launch. The development app has its own identity (`com.jianfeng.pi-mac.dev`), with notification permissions and preferences separate from the release app. Task completion notifications appear in both foreground and background and use the default system sound. Bare executables launched with `swift run` do not support system notifications.

The watcher owns relaunches: the app drains services and waits for the child lease, submits a restart handoff, then exits. Only after reaping the old app does the watcher launch the replacement and check its heartbeat within 30 seconds. Handoff/startup timeouts report an error instead of waiting indefinitely or launching a second owner. After upgrading the watcher, stop the old watcher with Ctrl-C and run `python3 scripts/dev.py` again.

The watcher prints compact timestamped build/change/reload statuses. Full output is saved to `.build/dev-build.log` (latest build), `.build/dev-app.log` (app lifecycle output, appended across launches), and `.build/dev-watch.log` (watcher lifecycle, appended); failed builds also print the last 40 lines. Use `python3 scripts/dev.py --verbose` to show build details and live app logs in the terminal.

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
