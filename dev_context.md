# Marmy - Developer Context

## What is Marmy?

Marmy is a productivity tool that enables mobile access to Claude Code agent sessions running on a laptop. It creates a bridge between an iOS device and tmux sessions via a Tailscale VPN connection, allowing users to manage and interact with Claude Code agents remotely through voice-enabled control.

**Core Purpose:** Remote management and interaction with Claude Code agents from anywhere, with full terminal interaction and voice capabilities.

## Architecture Overview

```
iOS Client (Marmy App)
        |
        | (REST/WebSocket over Tailscale VPN)
        v
Marmy API Server (Node.js/TypeScript/Fastify)
        |
        | (tmux commands via shell)
        v
Local tmux Sessions (Claude Code agents)
```

Key architectural principles:
- Isolated backend serving the frontend via REST + WebSocket
- Session lazy-loading (only create when first message is sent)
- Git workflow enforcement through CLAUDE.md files
- One-to-one mapping: Project folder = tmux session = Claude Code instance

## Technology Stack

### Backend (`/api`)
- **Runtime:** Node.js 20+
- **Language:** TypeScript 5.5+
- **Framework:** Fastify 4.28+
- **Networking:** REST API + WebSocket via @fastify/websocket
- **Validation:** Zod
- **Configuration:** YAML files + dotenv
- **Logging:** Pino

### Frontend (`/ios`)
- **Language:** Swift 5.9+
- **UI Framework:** SwiftUI with @Observable
- **Minimum iOS:** 17.0
- **Architecture:** MVVM pattern
- **Voice:** AVSpeechSynthesizer (TTS) + Speech framework (STT)
- **Security:** Keychain for auth token storage

## Directory Structure

```
marmy/
├── api/                      # Backend server
│   ├── src/
│   │   ├── index.ts          # Entry point
│   │   ├── server.ts         # Fastify setup
│   │   ├── config.ts         # Configuration loading
│   │   ├── routes/           # API endpoints
│   │   ├── services/         # Business logic (tmux, project, session)
│   │   ├── middleware/       # Auth middleware
│   │   ├── types/            # TypeScript interfaces
│   │   └── utils/            # Helper utilities
│   └── config/
│       └── default.yaml      # Default configuration
├── ios/                      # iOS app
│   └── marmy/
│       ├── App/              # App entry point
│       ├── Models/           # Data structures
│       ├── ViewModels/       # MVVM view models
│       ├── Views/            # SwiftUI views
│       ├── Services/         # API client, WebSocket, Voice
│       └── Utils/            # Extensions
├── shared/                   # Shared types (minimal)
├── SPEC.md                   # Product specification
├── backend_plan.md           # Backend implementation plan
└── frontend_plan.md          # Frontend implementation plan
```

## Key Features

1. **Project Discovery & Management**
   - Scans workspace directory for projects
   - Identifies git-initialized projects
   - Reports current git branch per project

2. **Session Lifecycle**
   - Lazy session initialization on first message
   - Automatic CLAUDE.md creation for git workflow rules
   - Auto-start Claude Code CLI in sessions

3. **Terminal Interaction**
   - Real-time terminal output streaming via WebSocket
   - Text input with submit functionality
   - Special key support (arrows, Ctrl+C, Escape, Tab, etc.)

4. **Voice Features**
   - Text-to-speech for reading terminal output
   - Speech-to-text for dictating commands

## API Endpoints

| Method | Endpoint | Purpose |
|--------|----------|---------|
| GET | `/api/health` | Health check |
| GET | `/api/info` | Server info |
| GET | `/api/projects` | List all projects |
| GET | `/api/projects/:name` | Get project details |
| GET | `/api/sessions` | List active sessions |
| GET | `/api/sessions/:id` | Get session details |
| GET | `/api/sessions/:id/content` | Get terminal output |
| POST | `/api/sessions/:id/submit` | Send text to session |
| POST | `/api/sessions/:id/keys` | Send special keys |
| DELETE | `/api/sessions/:id` | Kill session |
| WS | `/api/sessions/:id/stream` | Real-time streaming |

## Running the Project

### Backend
```bash
cd api
npm install
npm run dev      # Development
npm run build && npm start  # Production
```

### Configuration

Backend config via `api/config/default.yaml` or environment variables:
- `MARMY_AUTH_TOKEN` - Authentication token
- `MARMY_HOST` - Server host
- `MARMY_PORT` - Server port
- `MARMY_WORKSPACE_PATH` - Workspace directory

### Tailscale Setup
1. Install Tailscale on laptop
2. Get Tailscale IP (e.g., 100.64.0.1)
3. Configure iOS app with Tailscale IP and auth token
4. Both devices must be on same Tailnet

## Security Model

- Bearer token authentication on all endpoints (except health)
- Tailscale VPN provides encryption and device authentication
- iOS Keychain for secure token storage
- Git workflow rules prevent direct commits to main/master

## Honest Assessment

### Is It Cool?

Yes. The core idea is genuinely useful - being able to check on, interact with, and control Claude Code agents from your phone while away from your desk solves a real problem. The voice integration isn't just a gimmick; it makes sense for mobile where typing is painful. Combining tmux (battle-tested terminal multiplexing), Tailscale (zero-config VPN), and Claude Code into a cohesive mobile experience is clever.

### Strengths

1. **Solves a real problem** - Developers often want to monitor long-running agent tasks or quickly respond to prompts without being at their laptop. This fills that gap.

2. **Smart technology choices** - Tailscale for networking (no port forwarding, encrypted by default), tmux for session persistence (survives server restarts), Fastify for performance. These are pragmatic picks.

3. **Lazy session creation** - Not spinning up resources until actually needed is efficient and prevents orphaned sessions.

4. **Simple mental model** - One project = one session = one Claude Code instance. No complex multi-tenancy or session management to think about.

5. **Git safety rails** - Auto-generating CLAUDE.md with branch protection rules prevents the "oops I committed to main from my phone" disaster.

6. **Voice-first mobile design** - TTS to hear output and STT to dictate commands acknowledges that mobile terminals are awkward. Leaning into voice is the right call.

7. **WebSocket with polling fallback** - Graceful degradation when real-time streaming isn't available.

### Weaknesses

1. **Single-user only** - Hardcoded workspace path, no user accounts, no multi-tenancy. Fine for personal use, but can't share with teammates or scale.

2. **No persistence layer** - No database means no session history, no conversation logs, no ability to resume context after a session dies. Everything is ephemeral.

3. **Terminal on mobile is inherently awkward** - Even with voice, reading/navigating terminal output on a small screen is challenging. The UX ceiling is low.

4. **Tailscale dependency** - Requires both devices on the same Tailnet. Can't quickly share access with someone not on your network.

5. **Limited error recovery** - What happens when tmux dies? When Claude Code crashes mid-session? When the laptop sleeps? These edge cases could leave users stranded.

6. **No offline support** - iOS app is useless without network connectivity to the backend. No cached state or queued commands.

7. **Basic security** - Bearer token auth works but there's no rate limiting, no token rotation, no audit logging. Acceptable for personal use over Tailscale, but wouldn't pass a security review.

8. **No test coverage visible** - The codebase structure doesn't show tests. For a tool managing code agents, this is risky.

9. **Polling inefficiency** - The fallback polling approach and hash-based change detection could miss rapid updates or waste bandwidth on unchanged content.

### Bottom Line

Marmy is a well-executed personal productivity tool with a clear vision. It's not trying to be enterprise software - it's solving a specific problem (mobile Claude Code access) for a specific user (the developer who built it). The weaknesses are acceptable trade-offs for that scope. If you want to expand it beyond personal use, you'd need to address persistence, multi-user support, and robustness. But as a "scratch your own itch" project, it's solid.
