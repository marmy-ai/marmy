# Marmy - Mobile Agent Remote Management

## Overview

Marmy is a productivity tool that enables coding from anywhere by providing mobile access to tmux sessions running Claude Code agents. Users connect to their laptop via Tailscale mesh VPN and interact with active coding sessions through a native iOS app with voice capabilities.

## Architecture

```
┌─────────────────┐         Tailscale VPN         ┌─────────────────┐
│   iOS Client    │◄──────────────────────────────►│  Laptop Server  │
│                 │                                │                 │
│  - Session list │         REST/WebSocket         │  - marmy-api    │
│  - Terminal view│◄──────────────────────────────►│  - tmux sessions│
│  - Voice I/O    │                                │  - Claude Code  │
└─────────────────┘                                └─────────────────┘
```

## Workspace & Session Model

### Workspace Directory

The workspace root is:
```
/Users/mharajli/Desktop/agent_space/
```

Each subdirectory (except `marmy/`) represents a **project** that can have an associated Claude Code session.

```
agent_space/
├── marmy/              # This tool (excluded from sessions)
├── project-alpha/      # → Session: project-alpha
├── my-website/         # → Session: my-website
├── api-backend/        # → Session: api-backend
└── ...
```

### Session Rules

1. **One Session Per Project**: Each project folder maps to exactly one tmux session. Session name = folder name.

2. **Lazy Initialization**: Sessions are NOT created upfront. A session is only created when the user sends their first message to that project.

3. **Project Discovery**: The API scans `agent_space/` for subdirectories to build the project list. Projects without active sessions show as "inactive" in the UI.

### Git Workflow Rules

These rules ensure safe, reviewable code changes:

| Rule | Description |
|------|-------------|
| **Git Required** | The agent will NOT make code changes unless the project folder has git initialized (`.git/` exists). |
| **Branch-Only Work** | All code changes MUST happen on a branch. The agent will NEVER commit directly to `main` or `master`. |
| **No Merging** | The agent can create branches and commit to them, but will NEVER merge branches. Merging is a human responsibility. |
| **Auto-Branch Creation** | When starting work, if on main/master, the agent creates a new branch (e.g., `claude/fix-login-bug`). |

### Branch Naming Convention

Agent-created branches follow the pattern:
```
claude/<short-description>
```

Examples:
- `claude/add-user-auth`
- `claude/fix-navbar-styling`
- `claude/refactor-api-routes`

### Pre-Coding Checks

Before making any code changes, the agent verifies:

```bash
# 1. Check git is initialized
[ -d .git ] || echo "ERROR: Git not initialized"

# 2. Check current branch
current_branch=$(git branch --show-current)
if [[ "$current_branch" == "main" || "$current_branch" == "master" ]]; then
  # Create and switch to new branch
  git checkout -b claude/<task-description>
fi

# 3. Proceed with coding
```

## Monorepo Structure

```
marmy/
├── SPEC.md
├── api/                    # Server-side API (runs on laptop)
│   ├── src/
│   ├── package.json        # Node.js/TypeScript or similar
│   └── ...
├── ios/                    # Native Swift iOS app
│   ├── Marmy/
│   ├── Marmy.xcodeproj
│   └── ...
└── shared/                 # Shared types/protocols (if needed)
```

## Components

### 1. Marmy API (Server)

A local HTTP server running on the laptop that interfaces with tmux.

#### Technology Choices
- **Language**: TypeScript (Node.js) or Go
- **Framework**: Express/Fastify (Node) or net/http (Go)
- **Transport**: REST + WebSocket for real-time terminal output

#### Endpoints

##### Projects

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/projects` | List all project folders (with session status) |
| GET | `/api/projects/:name` | Get project details (git status, has session, etc.) |

##### Sessions

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/sessions` | List all active tmux sessions |
| GET | `/api/sessions/:id` | Get session details |
| DELETE | `/api/sessions/:id` | Kill a session |

*Note: Sessions are created lazily via `/submit` - no explicit POST to create.*

##### Session Interaction

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/sessions/:id/content` | Capture current terminal content |
| POST | `/api/sessions/:id/keys` | Send special key sequences (arrows, Enter, Escape, etc.) |
| POST | `/api/sessions/:id/input` | Send raw text to session |
| POST | `/api/sessions/:id/submit` | Send text + Enter (creates session if needed) |
| WebSocket | `/api/sessions/:id/stream` | Real-time terminal output stream |

##### System

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/health` | Health check |
| GET | `/api/info` | Server info (hostname, version) |

#### Data Models

```typescript
interface Project {
  name: string;            // folder name (e.g., "my-website")
  path: string;            // full path to project
  hasGit: boolean;         // whether .git/ exists
  gitBranch?: string;      // current branch if git initialized
  hasSession: boolean;     // whether tmux session is active
  sessionId?: string;      // tmux session name if active
}

interface Session {
  id: string;              // tmux session name (= project folder name)
  projectName: string;     // associated project
  projectPath: string;     // full path to project folder
  created: string;         // ISO timestamp
  attached: boolean;       // whether a client is attached
  windows: Window[];
  lastActivity: string;
}

interface Window {
  index: number;
  name: string;
  active: boolean;
  panes: Pane[];
}

interface Pane {
  index: number;
  active: boolean;
  pid: number;
  currentCommand: string;
  width: number;
  height: number;
}

interface SessionContent {
  sessionId: string;
  content: string;         // captured terminal text
  cursorX: number;
  cursorY: number;
  timestamp: string;
}

interface InputRequest {
  text: string;
  submit?: boolean;        // if true, append Enter key
}

interface KeyInput {
  key: SpecialKey;
}

type SpecialKey =
  | "Up"
  | "Down"
  | "Left"
  | "Right"
  | "Enter"
  | "Escape"
  | "Tab"
  | "Backspace"
  | "CtrlC"      // Interrupt
  | "CtrlD"      // EOF
  | "CtrlZ";     // Suspend
```

### Interactive Input Handling

Claude Code uses interactive prompts that require special key navigation:
- **Option selection**: Arrow keys (↑↓) to navigate, Enter to select
- **Yes/No prompts**: Type 'y' or 'n', or use arrow keys
- **Interrupts**: Ctrl+C to cancel operations

#### Key Button Controls

The iOS app provides quick-action buttons for common keys:

```
┌─────────────────────────────────────┐
│  [↑]  [↓]  [←]  [→]                │  Arrow keys
│  [Enter]  [Esc]  [Tab]              │  Confirmation/navigation
│  [Ctrl+C]  [Ctrl+D]                 │  Interrupt/EOF
└─────────────────────────────────────┘
```

These buttons send key sequences via `POST /api/sessions/:id/keys`:

```bash
# Send arrow down
curl -X POST http://host:3000/api/sessions/my-project/keys \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"key": "Down"}'

# Send Enter to confirm selection
curl -X POST http://host:3000/api/sessions/my-project/keys \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"key": "Enter"}'
```

#### tmux Key Mapping

The API translates key names to tmux send-keys format:

| Key | tmux send-keys |
|-----|----------------|
| Up | `send-keys Up` |
| Down | `send-keys Down` |
| Left | `send-keys Left` |
| Right | `send-keys Right` |
| Enter | `send-keys Enter` |
| Escape | `send-keys Escape` |
| Tab | `send-keys Tab` |
| Backspace | `send-keys BSpace` |
| CtrlC | `send-keys C-c` |
| CtrlD | `send-keys C-d` |
| CtrlZ | `send-keys C-z` |

#### tmux Integration

The API uses tmux CLI commands:

```bash
# List sessions
tmux list-sessions -F "#{session_name}:#{session_created}:#{session_attached}"

# Capture pane content
tmux capture-pane -t <session>:<window>.<pane> -p

# Send keys to session
tmux send-keys -t <session> "text here" Enter

# Get session info
tmux display-message -t <session> -p "#{...}"
```

#### Security Considerations

- **Authentication**: Bearer token auth (simple shared secret for personal use)
- **Binding**: Listen on Tailscale interface only (100.x.x.x) or localhost
- **Rate limiting**: Optional, to prevent accidental spam

### 2. Marmy iOS App

A native Swift app for iPhone (and iPad).

#### Features

1. **Session Management**
   - List all active tmux sessions
   - Create new sessions (optionally with Claude Code started)
   - Kill sessions

2. **Terminal Viewer**
   - Display captured terminal content
   - Auto-refresh or WebSocket streaming
   - Scroll through history
   - Pinch to zoom

3. **Input Methods**
   - Text input field for typing commands
   - Quick-submit button (sends + Enter)
   - Keyboard shortcuts/snippets

4. **Voice Capabilities**
   - **Text-to-Speech**: Read terminal output aloud (useful for hands-free)
   - **Speech-to-Text**: Dictate commands/prompts
   - Voice activation option ("Hey Marmy, submit...")

5. **Notifications**
   - Push notifications when agent completes a task (requires detecting idle state)
   - Background polling or persistent WebSocket

#### Technology Choices

- **UI**: SwiftUI
- **Networking**: URLSession + native WebSocket
- **Voice**: AVSpeechSynthesizer (TTS), Speech framework (STT)
- **State**: SwiftUI @Observable or TCA if complexity warrants

#### Screens

1. **Home/Session List**
   - List of sessions with status indicators
   - Pull to refresh
   - Tap to open, swipe to delete

2. **Session Detail/Terminal View**
   - Terminal content display (monospace font)
   - Input bar at bottom
   - Toolbar: refresh, voice read, settings

3. **Settings**
   - Server URL configuration
   - Auth token
   - Voice settings (speed, voice selection)
   - Theme (light/dark terminal)

### 3. Shared Components

If using TypeScript for API, could share types via:
- OpenAPI spec generation
- Manual Swift type definitions matching API

## Implementation Phases

### Phase 1: Core API
- [ ] Project setup (Node.js + TypeScript)
- [ ] tmux wrapper utilities
- [ ] REST endpoints for sessions CRUD
- [ ] Session content capture endpoint
- [ ] Input/submit endpoints
- [ ] Basic auth middleware

### Phase 2: Real-time Streaming
- [ ] WebSocket server setup
- [ ] Terminal content streaming
- [ ] Efficient diff-based updates (optional optimization)

### Phase 3: iOS App Foundation
- [ ] Xcode project setup
- [ ] Networking layer
- [ ] Session list view
- [ ] Server configuration UI

### Phase 4: Terminal Viewer
- [ ] Terminal content display
- [ ] Auto-refresh
- [ ] WebSocket integration
- [ ] Input handling

### Phase 5: Voice Features
- [ ] Text-to-speech integration
- [ ] Speech-to-text for dictation
- [ ] Voice command processing

### Phase 6: Polish
- [ ] Push notifications
- [ ] Widget support
- [ ] Apple Watch companion (stretch goal)
- [ ] iPad optimization

## API Examples

### List Sessions

```bash
curl http://100.x.x.x:3000/api/sessions \
  -H "Authorization: Bearer <token>"
```

```json
{
  "sessions": [
    {
      "id": "claude-frontend",
      "created": "2026-01-17T10:30:00Z",
      "attached": false,
      "windows": [{"index": 0, "name": "main", "active": true}]
    },
    {
      "id": "claude-backend",
      "created": "2026-01-17T09:15:00Z",
      "attached": true,
      "windows": [{"index": 0, "name": "main", "active": true}]
    }
  ]
}
```

### Get Session Content

```bash
curl http://100.x.x.x:3000/api/sessions/claude-frontend/content \
  -H "Authorization: Bearer <token>"
```

```json
{
  "sessionId": "claude-frontend",
  "content": "$ claude\n\nWelcome to Claude Code...\n\n> What would you like to do?\n\n█",
  "timestamp": "2026-01-17T14:22:33Z"
}
```

### Submit Input

```bash
curl -X POST http://100.x.x.x:3000/api/sessions/claude-frontend/submit \
  -H "Authorization: Bearer <token>" \
  -H "Content-Type: application/json" \
  -d '{"text": "Fix the bug in the login component"}'
```

## Configuration

### Server (marmy-api)

```yaml
# config.yaml
port: 3000
host: "100.x.x.x"  # Tailscale IP, or 0.0.0.0
auth:
  token: "your-secret-token"
tmux:
  defaultShell: "/bin/zsh"
  captureLines: 500  # lines of scrollback to capture
```

### iOS App

Stored in UserDefaults/Keychain:
- Server URL
- Auth token
- Voice preferences

## Open Questions / Future Considerations

1. ~~**Session Naming Convention**~~: Resolved - sessions are named after their project folder.
2. **Multiple Panes**: Support for tmux split panes, or focus on single-pane sessions?
3. **File Access**: Should the API expose file read/write for quick edits?
4. ~~**Session Templates**~~: Resolved - sessions auto-start with Claude Code in the project directory.
5. **Collaboration**: Multiple devices connecting to same session?
6. **Offline Queueing**: Queue commands when disconnected, send when reconnected?
7. **Non-Git Projects**: Allow read-only exploration of projects without git? (Currently blocked from coding)

## Dependencies

### API
- Node.js 20+ or Go 1.21+
- tmux 3.0+

### iOS
- iOS 17+ (for latest SwiftUI features)
- Xcode 15+

## Getting Started

```bash
# Clone and setup
cd marmy

# Start API
cd api
npm install
npm run dev

# iOS - open in Xcode
open ios/Marmy.xcodeproj
```

---

*Marmy: Your agents, anywhere.*
