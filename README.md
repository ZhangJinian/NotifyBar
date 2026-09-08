<p align="center"><img src="Resources/terminal.png" width="128" alt="NotifyBar logo"></p>

# NotifyBar

English | [简体中文](README-cn.md)

A lightweight macOS menu bar and Touch Bar utility for monitoring Codex quotas, tracking Codex and OpenCode tasks, and receiving clickable task notifications.

Built with Swift and AppKit, with no third-party runtime dependencies.

## Features

- **Codex quotas:** remaining 5-hour and 7-day allowances with local reset times. Percentages shift from green to red as the allowance decreases. Refreshes every minute.
- **Background Touch Bar:** compact 198 × 30 point blocks that remain visible when switching apps. The OpenCode block appears automatically while OpenCode is running.
- **Task menu:** detected conversations grouped by Codex and OpenCode, with status and clickable navigation.
- **Multiple instances:** OpenCode indicators grouped by Terminal and VS Code, with one light per instance. Tap the block to cycle through instances.
- **Notifications:** include the source, conversation name, and event: completed, awaiting authorization, awaiting an answer, or terminated. Click to open the corresponding interface.

| State | Codex border | OpenCode indicator |
| --- | --- | --- |
| Idle | None | Green |
| Working | Pulsing blue | Pulsing blue |
| Awaiting authorization or an answer | Orange | Orange |
| Completed, unread | Red | Red |

## Build and install

Requires macOS 12 or later. Touch Bar features require a Mac with a Touch Bar; the menu bar and notifications can be used independently.

Install Xcode Command Line Tools if needed:

```sh
xcode-select --install
```

From the project directory:

```sh
./build.sh
open build/NotifyBar.app
```

Drag `build/NotifyBar.app` into Applications to install it. Use the terminal icon in the menu bar to access controls. To launch at login, add the app to macOS Login Items.

Codex quota monitoring requires an installed, signed-in Codex / ChatGPT desktop app. The current integration looks for the bundled Codex executable under `/Applications/ChatGPT.app`. OpenCode must be installed and running locally.

## Permissions and notifications

Allow notifications when prompted. For persistent on-screen notifications, choose the Alerts style in macOS notification settings. Delivery also depends on notification permissions and Focus settings.

Navigating to Terminal or VS Code may require Automation permission. Focusing the VS Code integrated terminal uses keyboard automation and may require Accessibility permission. The app does not use the microphone or provide voice controls.

## How it works and current limitations

- Codex quotas come from the local `codex app-server` endpoint `account/rateLimits/read`. No API key needs to be entered.
- Codex task state comes from local IPC and unread records; titles come from the local session index. VS Code routing uses project assignments saved by its extension.
- OpenCode monitoring reads local processes, its SQLite database, and logs. Terminal navigation uses TTY identifiers; VS Code navigation uses the working directory and focuses the integrated terminal.
- The app reads local titles, state, and application storage for display. It does not initiate model requests or upload that data.
- Background Touch Bar presentation uses private macOS interfaces. OS or upstream application updates may require changes. NotifyBar manages the left application area; unused space can host additional NotifyBar blocks, but not buttons from other apps.
- OpenCode process-to-session mapping and approval-log interpretation are heuristic. Multiple instances in the same directory, resumed sessions, and parallel subtasks may be misidentified. Exact tab selection among multiple VS Code terminals in one window is not guaranteed.
- Termination is reported only when an explicit interruption marker is recognized. Without that marker, cancellation cannot reliably be distinguished from other ways a task ends.
- The menu lists connected, discoverable conversations, not the complete conversation history. Reopen the menu to refresh its displayed state.
- Builds target the local machine architecture and use ad hoc signing. They are not signed with an Apple Developer certificate or notarized.

## Checks

```sh
./build.sh
build/NotifyBar.app/Contents/MacOS/NotifyBar --self-test
build/NotifyBar.app/Contents/MacOS/NotifyBar --probe
build/NotifyBar.app/Contents/MacOS/NotifyBar --activity-probe
build/NotifyBar.app/Contents/MacOS/NotifyBar --opencode-probe
```

Self-checks cover quota parsing, colors, task state, and routing classification. Live probes require the corresponding local app to be running. Passing self-checks does not establish compatibility with every terminal setup or upstream version.

## License and acknowledgements

Derived from CodexBar and extended for task monitoring. The copyright notices for Jack Chen and wjx8 are preserved. Licensed under the [MIT License](LICENSE).
