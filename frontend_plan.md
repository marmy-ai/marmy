# Marmy iOS App - Frontend Implementation Plan

## Overview

Native iOS app that connects to the Marmy API to manage and interact with Claude Code sessions running in tmux on a remote laptop via Tailscale VPN.

## Tech Stack

- **Language**: Swift 5.9+
- **UI Framework**: SwiftUI
- **Minimum iOS**: 17.0
- **Architecture**: MVVM with @Observable
- **Networking**: URLSession + native WebSocket
- **Voice**: AVFoundation (TTS), Speech framework (STT)
- **Storage**: UserDefaults (settings), Keychain (auth token)

## Project Structure

```
ios/marmy/marmy/
├── App/
│   └── marmyApp.swift
├── Models/
│   ├── Project.swift
│   ├── Session.swift
│   └── ServerConfig.swift
├── ViewModels/
│   ├── ProjectListViewModel.swift
│   ├── SessionViewModel.swift
│   └── SettingsViewModel.swift
├── Views/
│   ├── ProjectListView.swift
│   ├── SessionDetailView.swift
│   ├── TerminalView.swift
│   ├── InputBarView.swift
│   ├── KeyControlsView.swift
│   └── SettingsView.swift
├── Services/
│   ├── APIClient.swift
│   ├── WebSocketManager.swift
│   ├── VoiceService.swift
│   └── KeychainService.swift
├── Utils/
│   └── Extensions.swift
└── Assets.xcassets/
```

## Data Models

### Project.swift

```swift
struct Project: Identifiable, Codable {
    let name: String
    let path: String
    let hasGit: Bool
    let gitBranch: String?
    let hasSession: Bool
    let sessionId: String?

    var id: String { name }
}
```

### Session.swift

```swift
struct Session: Identifiable, Codable {
    let id: String
    let projectName: String
    let projectPath: String
    let created: Date
    let attached: Bool
    let lastActivity: Date
}

struct SessionContent: Codable {
    let sessionId: String
    let content: String
    let timestamp: Date
}
```

### ServerConfig.swift

```swift
struct ServerConfig: Codable {
    var host: String        // e.g., "100.x.x.x"
    var port: Int           // e.g., 3000
    var authToken: String

    var baseURL: URL {
        URL(string: "http://\(host):\(port)")!
    }
}
```

## Implementation Tasks

### Phase 1: Foundation

#### 1.1 Project Setup
- [ ] Create folder structure (Models/, Views/, ViewModels/, Services/, Utils/)
- [ ] Add `.gitignore` for Xcode artifacts
- [ ] Configure app target for iOS 17+

#### 1.2 Networking Layer - `APIClient.swift`
- [ ] Implement base HTTP client with URLSession
- [ ] Add bearer token authentication header injection
- [ ] Implement request/response logging for debugging
- [ ] Handle common errors (network, auth, server errors)
- [ ] Implement endpoints:
  - `GET /api/projects` → `[Project]`
  - `GET /api/projects/:name` → `Project`
  - `GET /api/sessions` → `[Session]`
  - `GET /api/sessions/:id` → `Session`
  - `GET /api/sessions/:id/content` → `SessionContent`
  - `POST /api/sessions/:id/keys` → `Void` (body: `{"key": "Up|Down|Enter|..."}`)
  - `POST /api/sessions/:id/submit` → `Void` (body: `{"text": "..."}`)
  - `DELETE /api/sessions/:id` → `Void`
  - `GET /api/health` → health check

#### 1.3 Configuration Storage
- [ ] `KeychainService.swift` - secure storage for auth token
- [ ] UserDefaults wrapper for non-sensitive settings (host, port, voice prefs)

### Phase 2: Core UI

#### 2.1 Project List View
- [ ] `ProjectListViewModel.swift`
  - Fetch projects from API
  - Track loading/error states
  - Pull-to-refresh support
- [ ] `ProjectListView.swift`
  - List of projects with status indicators:
    - Green dot: active session
    - Gray dot: no session
    - Git icon: has git initialized
    - Warning icon: no git (can't code)
  - Tap project → navigate to session detail
  - Pull to refresh
  - Empty state when no projects

#### 2.2 Session Detail View
- [ ] `SessionViewModel.swift`
  - Fetch session content
  - Submit input to session
  - Auto-refresh content (polling initially, WebSocket later)
  - Handle session creation on first submit
- [ ] `SessionDetailView.swift`
  - Display project name and git branch
  - Terminal content area (scrollable)
  - Input bar at bottom
  - Toolbar actions: refresh, voice read, kill session

#### 2.3 Terminal View
- [ ] `TerminalView.swift`
  - Monospace font rendering (SF Mono or Menlo)
  - Dark background, light text (terminal aesthetic)
  - Auto-scroll to bottom on new content
  - Manual scroll with "jump to bottom" button
  - Pinch to zoom (adjust font size)
  - Copy text on long press

#### 2.4 Input Bar
- [ ] `InputBarView.swift`
  - Text field for input
  - Submit button (sends text + creates session if needed)
  - Microphone button for voice input
  - Keyboard handling (dismiss, return key behavior)

#### 2.5 Key Controls (for Interactive Prompts)
- [ ] `KeyControlsView.swift`
  - Quick-action buttons for Claude Code interactive prompts
  - Layout:
    ```
    ┌─────────────────────────────────────┐
    │  [↑]  [↓]  [←]  [→]                │  Arrow keys
    │  [Enter]  [Esc]  [Tab]              │  Confirmation
    │  [Ctrl+C]  [Ctrl+D]                 │  Interrupt/EOF
    └─────────────────────────────────────┘
    ```
  - Each button calls `POST /api/sessions/:id/keys` with the key name
  - Haptic feedback on tap
  - Optional: collapsible/expandable panel
- [ ] Add `SpecialKey` enum:
  ```swift
  enum SpecialKey: String, Codable {
      case up = "Up"
      case down = "Down"
      case left = "Left"
      case right = "Right"
      case enter = "Enter"
      case escape = "Escape"
      case tab = "Tab"
      case backspace = "Backspace"
      case ctrlC = "CtrlC"
      case ctrlD = "CtrlD"
      case ctrlZ = "CtrlZ"
  }
  ```
- [ ] Integrate into `SessionDetailView` below the terminal, above text input

### Phase 3: Settings

#### 3.1 Settings View
- [ ] `SettingsViewModel.swift`
- [ ] `SettingsView.swift`
  - Server configuration:
    - Host input (with Tailscale IP hint)
    - Port input (default 3000)
    - Auth token input (secure field)
    - Test connection button
  - Voice settings:
    - TTS enabled toggle
    - TTS voice selection
    - TTS speech rate slider
    - STT language selection
  - App info (version, build)

### Phase 4: Real-time Updates

#### 4.1 WebSocket Integration
- [ ] `WebSocketManager.swift`
  - Connect to `ws://host:port/api/sessions/:id/stream`
  - Handle connection lifecycle (connect, disconnect, reconnect)
  - Parse incoming terminal content updates
  - Exponential backoff for reconnection
- [ ] Update `SessionViewModel` to use WebSocket when available
- [ ] Fallback to polling if WebSocket fails

### Phase 5: Voice Features

#### 5.1 Text-to-Speech
- [ ] `VoiceService.swift` - TTS implementation
  - Use AVSpeechSynthesizer
  - Read terminal output aloud
  - Smart reading (skip ANSI codes, read meaningful content)
  - Stop/pause controls
- [ ] Add "Read" button to SessionDetailView toolbar
- [ ] Auto-read new content option

#### 5.2 Speech-to-Text
- [ ] Add STT to `VoiceService.swift`
  - Use Speech framework (SFSpeechRecognizer)
  - Request microphone + speech recognition permissions
  - Real-time transcription to input field
- [ ] Microphone button in InputBarView
  - Tap to start/stop recording
  - Visual feedback during recording
  - Auto-submit option after silence

### Phase 6: Polish

#### 6.1 Error Handling & Edge Cases
- [ ] Network error states with retry buttons
- [ ] Server unreachable handling
- [ ] Session killed externally handling
- [ ] Empty project list state
- [ ] No git warning when trying to interact

#### 6.2 UI Polish
- [ ] App icon
- [ ] Launch screen
- [ ] Haptic feedback on actions
- [ ] Loading indicators
- [ ] Smooth animations/transitions

#### 6.3 Background & Notifications (Stretch)
- [ ] Background refresh for session status
- [ ] Local notifications when session becomes idle
- [ ] Widget showing active sessions

## API Contract

The app expects these endpoints from the backend:

### Projects
```
GET /api/projects
Authorization: Bearer <token>

Response:
{
  "projects": [
    {
      "name": "my-website",
      "path": "/Users/.../agent_space/my-website",
      "hasGit": true,
      "gitBranch": "main",
      "hasSession": true,
      "sessionId": "my-website"
    }
  ]
}
```

### Sessions
```
GET /api/sessions/:id/content
Authorization: Bearer <token>

Response:
{
  "sessionId": "my-website",
  "content": "$ claude\n\nWelcome to Claude Code...\n\n> ",
  "timestamp": "2026-01-17T14:22:33Z"
}
```

### Submit Input
```
POST /api/sessions/:id/submit
Authorization: Bearer <token>
Content-Type: application/json

Body: {"text": "Fix the bug in login.swift"}

Response: 200 OK (empty body)
```

### Send Special Keys (for Interactive Prompts)
```
POST /api/sessions/:id/keys
Authorization: Bearer <token>
Content-Type: application/json

Body: {"key": "Down"}  // or "Up", "Enter", "Escape", "CtrlC", etc.

Response: 200 OK (empty body)
```

Supported keys: `Up`, `Down`, `Left`, `Right`, `Enter`, `Escape`, `Tab`, `Backspace`, `CtrlC`, `CtrlD`, `CtrlZ`

### WebSocket
```
WS /api/sessions/:id/stream
Authorization via query param: ?token=<token>

Messages (server → client):
{
  "type": "content",
  "data": {
    "content": "...",
    "timestamp": "..."
  }
}
```

## Testing Strategy

- **Unit Tests**: ViewModels, Services (mock API responses)
- **UI Tests**: Navigation flows, input handling
- **Manual Testing**: Real device over Tailscale connection

## Dependencies

No external dependencies required. Using native frameworks only:
- Foundation
- SwiftUI
- AVFoundation
- Speech

## Notes for Implementation Team

1. **Start with mock data** - Build UI with hardcoded data first, then integrate API
2. **Test on real device** - Simulator can't test Tailscale networking properly
3. **Handle offline gracefully** - VPN may disconnect, show appropriate states
4. **Keep terminal performant** - Large terminal output can be slow; consider virtualized list or truncation
5. **Accessibility** - VoiceOver support, Dynamic Type for terminal font scaling

## Open Questions

1. Should terminal support ANSI color codes? (Adds complexity)
2. Keyboard shortcuts via external keyboard?
3. iPad split-view support priority?
