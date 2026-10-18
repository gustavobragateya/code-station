# Contributing to Teya Code Station

This guide covers the development workflow and the technical details behind the app. For the user-facing overview and normal build instructions, see [README.md](README.md).

## Development setup

You need:

- macOS 15 or later
- Xcode 16 or another Swift 6 toolchain
- Git

The app has one Swift package dependency, [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), which Swift Package Manager resolves automatically.

Build and run the executable:

```bash
swift build --build-system native --disable-sandbox
swift run --build-system native --disable-sandbox
```

Create the app bundle used for normal manual testing:

```bash
./build-app.sh
open "build/Teya Code Station.app"
```

`build-app.sh` builds the `MenuBarApp` executable, copies its SwiftPM resource bundle into the app, adds the icon and `Info.plist`, and applies an ad-hoc signature. The result is written to `build/Teya Code Station.app`.

## Tests

Run the full test suite after changing code:

```bash
swift test --build-system native --disable-sandbox --no-parallel
```

Run a focused test while iterating:

```bash
swift test --build-system native --disable-sandbox --no-parallel --filter GitActionsTests
```

Run the suite serially because the AppKit, WebKit, process, and preference fixtures share host resources. The native build system avoids requiring the separate Metal shader toolchain.

Tests live in `Tests/MenuBarAppTests`. They cover session and transcript behavior, CLI stream parsing, Git and worktree operations, terminal and PTY integration, file browsing, Dispatch and OAuth flows, skills, settings, persistence, and UI-facing presentation logic.

Live background-task tests are opt-in because they use the installed agents and their signed-in accounts. They start `sleep 600`, send a follow-up, and cancel the task. Set `CODE_STATION_LIVE_AGENT_TESTS=1` and filter to `AgentSessionLiveTests`; optionally set `CODE_STATION_LIVE_AGENT=codex` or `copilot` to test only one. Codex uses an account-advertised model for this disposable test. Normal test runs use protocol fixtures and make no model calls.

Add tests for behavior and business logic. Trivial view wiring, accessors, and framework behavior do not need dedicated tests.

## Project structure

- `Package.swift` defines the macOS executable and test targets.
- `Sources/MenuBarApp/MenuBarApp.swift` creates the application window and shared services.
- `Sources/MenuBarApp/RootView.swift` owns the top-level navigation and tool sheets.
- `Sources/MenuBarApp/Projects` contains projects, workspaces, sessions, Git support, the chat UI, the file explorer, and transcript persistence.
- `Sources/MenuBarApp/Terminal` contains the PTY-backed terminal and SwiftTerm integration.
- `Sources/MenuBarApp/Dispatch` contains saved HTTP requests, environments, OAuth, and response handling.
- The remaining files in `Sources/MenuBarApp` contain MCP, skills, Docker, local AI, settings, logging, and shared UI components.
- `Tests/MenuBarAppTests` mirrors the main behaviors with unit and integration tests.

## Site defaults

Anything that belongs to one organisation rather than to the app lives in `site-defaults.json`: the environments Dispatch and troubleshooting use, the identity provider the APIs sign in against, the saved requests a first run starts with, the MCP presets offered in the Add server sheet, the skills marketplace, and the shortcuts a first run starts with. `SiteDefaults` reads the first valid file from these locations:

1. `$CODE_STATION_SITE_DEFAULTS`
2. A saved external configuration path
3. `~/Library/Application Support/com.teya.code-station/site-defaults.json`
4. `site-defaults.json` inside the app bundle

An unreadable or malformed file produces a visible warning and falls through to the next location. On first launch, the setup wizard can validate and import a local JSON file or clone one from a GitHub repository. Imports are copied to Application Support, then the shared defaults and empty first-run stores are reloaded in the same process. Skipping the step keeps the normal bundled or empty defaults.

Nothing is compiled in, so a plain checkout builds an app with all of it empty. `site-defaults.example.json` is a blank-slate example to copy. Organisation-owned settings are maintained outside this repository and can be imported during setup or folded into an app bundle with `build-app.sh`. The build script uses the file selected with `SITE_DEFAULTS` and defaults to an untracked `site-defaults.json`. The [site configuration guide](docs/site-configuration.md) covers each field. Every section is optional.

Keep organisation-specific hostnames, client IDs, and repository URLs in that file rather than in Swift, so the code stays free of them. Tests should pass in whatever settings they need rather than reading `SiteDefaults.current`, so they pass on a checkout that has no site file.

## Runtime design

`AppDelegate` is the composition root. It creates the observable stores and services once, injects them into the SwiftUI environment, and shuts down child processes and terminals when the app quits.

A project is a reference to a folder on disk. A workspace is a reusable group of projects with one lead project. When a session starts, it records its own project paths and worktree choices so later workspace edits do not change an existing conversation.

`SessionRunner` owns agent connections, turn execution, and the prompt queue. `SessionComposerStore` keeps unsent drafts and prompt-history cursors. `ReviewCommentStore` keeps the comments left on a session's changes until they are sent back as one prompt, and runs second opinions: a read-only `SecondOpinion` run of another agent whose findings arrive as more comments. `AgentLaunchConfiguration` resolves settings once and supplies both command-line arguments and server parameters, so prompt text cannot be interpreted as an access setting. `AgentInstructions` holds the app guidance sent to agents.

The runner launches the selected agent in its own process group. Claude uses its streaming CLI protocol, Codex uses `app-server` JSON-RPC, and Copilot uses its headless server with Content-Length framing. The adapters normalize these protocols into shared `StreamEvent` values for the transcript and session state.

A server stays open while the agent has background work. Task lists are refreshed every five seconds while waiting, and Copilot also reports task changes. Follow-up messages use that same conversation. Ending the wait asks the agent to cancel its tasks before closing the process and cleaning up its process groups. The selected model, workspace roots, access limits, and disabled MCP servers carry into the server session. See [the persistent agent sessions decision](adr/0001-persistent-agent-sessions.md).

Git worktree sessions use a checkout and branch owned by that session. Workspace sessions may create a separate worktree for each Git project. A session using a project folder edits that folder directly. Git inspection is kept separate from the commands that switch, commit, pull, and push.

The terminal uses a real pseudo-terminal through SwiftTerm. Each tab owns its shell process and remains alive while the drawer is closed.

## Persistence and local processes

`ProjectStore` owns projects, sessions, and transcript lifetime. `ProjectNavigation` keeps selection, history, and sidebar reveal state. `ProjectPersistence` serializes transcript reads, writes, and removals so a queued write cannot recreate a deleted conversation. Ordinary metadata edits and streamed replies save in the background. Operations that require confirmed durability wait for a save and retain their rollback behavior.

App-owned data lives under:

```text
~/Library/Application Support/com.teya.code-station/
```

This includes the project and session index, one transcript file per session, saved HTTP requests, shortcuts, temporary attachments, unsent review comments, and the cached skills marketplace. Managed Git worktrees and their deletion queue live under `~/.code-station/`, which keeps tool working directories short and free of spaces. Small UI preferences use `UserDefaults`. OAuth client secrets and tokens use the macOS Keychain. Session logs live under `~/Library/Logs/com.teya.code-station`.

MCP definitions are read from and written to `~/.config/mcp/config.json`. The app uses those shared definitions when it registers a server in each coding agent's own configuration. Locally started MCP servers, shortcut commands, agent processes, and terminal shells are child processes owned by the app and are stopped when the app quits.

A Finder-launched app receives a limited `PATH`. Executable lookup also checks common Homebrew, local user, Go, and system binary directories. Use `ProcessManager.resolve` for new command-line integrations so they follow the same behavior.

## UI conventions

The app uses its own visual system instead of native controls with fixed macOS chrome.

- Use the shared colors and typography in `Theme.swift`.
- Show dialogs through `DialogPresenter` and the in-app `Dialog` type.
- Use `.appMenu` and `.appContextMenu` for menus.
- Use `ChoicePill` for segmented choices.
- Use `.appSwitch` and `.appCheckbox` for toggles.
- Style button labels explicitly and apply `.buttonStyle(.plain)`.
- Use plain text fields on a `Theme.field` background with a `Theme.border` stroke.
- Keep `NSOpenPanel` and `NSSavePanel` for file selection, where the system surface is expected.

Prefer existing controls and patterns before adding another variation. Comments should explain a constraint or reason that the code cannot make clear on its own.

## Before submitting a change

1. Build the package with `swift build --build-system native --disable-sandbox`.
2. Run `swift test --build-system native --disable-sandbox --no-parallel`.
3. For UI changes, build the app bundle and check the affected flow in the running app.
4. Review the diff for unrelated generated files or local configuration.

Keep commits focused and use a short imperative message such as `Improve session cleanup`.
