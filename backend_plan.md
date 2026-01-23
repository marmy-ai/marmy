# Marmy Backend - Implementation Plan

## Overview

Local HTTP server running on the user's laptop that manages tmux sessions running Claude Code agents. Exposes a REST API + WebSocket for the iOS client to interact with sessions remotely via Tailscale VPN.

## Tech Stack

- **Runtime**: Node.js 20+
- **Language**: TypeScript 5+
- **Framework**: Fastify (fast, TypeScript-friendly)
- **WebSocket**: @fastify/websocket
- **Validation**: Zod
- **Process**: child_process (for tmux commands)
- **Config**: dotenv + yaml

## Project Structure

```
api/
├── src/
│   ├── index.ts                 # Entry point
│   ├── server.ts                # Fastify server setup
│   ├── config.ts                # Configuration loading
│   ├── routes/
│   │   ├── projects.ts          # /api/projects endpoints
│   │   ├── sessions.ts          # /api/sessions endpoints
│   │   └── system.ts            # /api/health, /api/info
│   ├── services/
│   │   ├── tmux.ts              # tmux command wrapper
│   │   ├── project.ts           # Project discovery & git checks
│   │   └── session.ts           # Session management logic
│   ├── middleware/
│   │   └── auth.ts              # Bearer token authentication
│   ├── types/
│   │   ├── project.ts           # Project interfaces
│   │   ├── session.ts           # Session interfaces
│   │   └── api.ts               # Request/response types
│   └── utils/
│       ├── exec.ts              # Promisified exec wrapper
│       └── logger.ts            # Logging utility
├── config/
│   └── default.yaml             # Default configuration
├── package.json
├── tsconfig.json
└── README.md
```

## Configuration

### config/default.yaml

```yaml
server:
  host: "0.0.0.0"           # or specific Tailscale IP
  port: 3000

auth:
  token: "change-me-in-env" # Override via MARMY_AUTH_TOKEN env var

workspace:
  path: "/Users/mharajli/Desktop/agent_space"
  exclude:
    - "marmy"               # Exclude this project from sessions

tmux:
  captureLines: 1000        # Lines of scrollback to capture
  shell: "/bin/zsh"

claude:
  command: "claude"         # Command to start Claude Code
```

### Environment Variables

```bash
MARMY_AUTH_TOKEN=your-secret-token
MARMY_WORKSPACE_PATH=/path/to/workspace  # Optional override
```

## Implementation Tasks

### Phase 1: Project Setup

#### 1.1 Initialize Project
- [ ] Initialize npm project with TypeScript
  ```bash
  cd api
  npm init -y
  npm install fastify @fastify/websocket @fastify/cors zod yaml dotenv
  npm install -D typescript @types/node tsx
  ```
- [ ] Configure `tsconfig.json`
- [ ] Add npm scripts:
  - `dev`: `tsx watch src/index.ts`
  - `build`: `tsc`
  - `start`: `node dist/index.js`
- [ ] Set up `config.ts` to load YAML + env overrides

#### 1.2 Server Foundation - `server.ts`
- [ ] Initialize Fastify with logging
- [ ] Register CORS (allow all origins for local use)
- [ ] Register WebSocket plugin
- [ ] Register auth middleware
- [ ] Register route modules
- [ ] Graceful shutdown handling

#### 1.3 Auth Middleware - `middleware/auth.ts`
- [ ] Extract Bearer token from Authorization header
- [ ] Validate against configured token
- [ ] Return 401 on missing/invalid token
- [ ] Allow query param `?token=` for WebSocket connections

### Phase 2: Core Services

#### 2.1 Exec Utility - `utils/exec.ts`
- [ ] Promisified `child_process.exec` wrapper
- [ ] Configurable timeout
- [ ] Proper error handling with stderr capture

#### 2.2 tmux Service - `services/tmux.ts`

Wrapper for all tmux operations:

```typescript
interface TmuxService {
  // Session management
  listSessions(): Promise<TmuxSession[]>
  sessionExists(name: string): Promise<boolean>
  createSession(name: string, workingDir: string): Promise<void>
  killSession(name: string): Promise<void>

  // Content
  capturePane(session: string, lines?: number): Promise<string>

  // Input
  sendKeys(session: string, keys: string): Promise<void>
  sendText(session: string, text: string, submit?: boolean): Promise<void>
  sendSpecialKey(session: string, key: SpecialKey): Promise<void>
}

type SpecialKey =
  | "Up" | "Down" | "Left" | "Right"
  | "Enter" | "Escape" | "Tab" | "Backspace"
  | "CtrlC" | "CtrlD" | "CtrlZ";

// Maps SpecialKey to tmux send-keys format
const TMUX_KEY_MAP: Record<SpecialKey, string> = {
  Up: "Up",
  Down: "Down",
  Left: "Left",
  Right: "Right",
  Enter: "Enter",
  Escape: "Escape",
  Tab: "Tab",
  Backspace: "BSpace",
  CtrlC: "C-c",
  CtrlD: "C-d",
  CtrlZ: "C-z",
};
```

tmux commands reference:
```bash
# List sessions with format
tmux list-sessions -F "#{session_name}|#{session_created}|#{session_attached}|#{session_activity}"

# Check if session exists
tmux has-session -t <name> 2>/dev/null && echo "exists"

# Create new session (detached, with working directory)
tmux new-session -d -s <name> -c <working_dir>

# Kill session
tmux kill-session -t <name>

# Capture pane content (last N lines)
tmux capture-pane -t <session> -p -S -<lines>

# Send keys to session
tmux send-keys -t <session> "<text>" Enter
```

#### 2.3 Project Service - `services/project.ts`

```typescript
interface ProjectService {
  listProjects(): Promise<Project[]>
  getProject(name: string): Promise<Project | null>
  projectExists(name: string): Promise<boolean>
  hasGit(projectPath: string): Promise<boolean>
  getGitBranch(projectPath: string): Promise<string | null>
}
```

Implementation:
- [ ] Scan workspace directory for subdirectories
- [ ] Filter out excluded directories (e.g., "marmy")
- [ ] Check each project for `.git/` directory
- [ ] Get current git branch if git exists
- [ ] Cross-reference with active tmux sessions

#### 2.4 Session Service - `services/session.ts`

```typescript
interface SessionService {
  listSessions(): Promise<Session[]>
  getSession(id: string): Promise<Session | null>
  getSessionContent(id: string): Promise<SessionContent>
  ensureSession(projectName: string): Promise<Session>
  submitToSession(id: string, text: string): Promise<void>
  killSession(id: string): Promise<void>
}
```

Key behaviors:
- [ ] `ensureSession`: Creates session if it doesn't exist
  - Verify project exists
  - Check git is initialized (error if not)
  - Create tmux session with project directory as working dir
  - Start Claude Code in the session
- [ ] `submitToSession`: Send text to Claude Code
  - Ensure session exists (lazy creation)
  - Send keys via tmux

### Phase 3: REST API Routes

#### 3.1 System Routes - `routes/system.ts`

```
GET /api/health
Response: { "status": "ok", "timestamp": "..." }

GET /api/info
Response: {
  "version": "1.0.0",
  "hostname": "laptop.local",
  "workspace": "/Users/.../agent_space",
  "tmuxVersion": "3.6a"
}
```

#### 3.2 Project Routes - `routes/projects.ts`

```
GET /api/projects
Response: {
  "projects": [
    {
      "name": "my-website",
      "path": "/Users/.../agent_space/my-website",
      "hasGit": true,
      "gitBranch": "main",
      "hasSession": true,
      "sessionId": "my-website"
    },
    {
      "name": "new-project",
      "path": "/Users/.../agent_space/new-project",
      "hasGit": false,
      "gitBranch": null,
      "hasSession": false,
      "sessionId": null
    }
  ]
}

GET /api/projects/:name
Response: { ...single project... }
404 if not found
```

#### 3.3 Session Routes - `routes/sessions.ts`

```
GET /api/sessions
Response: {
  "sessions": [
    {
      "id": "my-website",
      "projectName": "my-website",
      "projectPath": "/Users/.../agent_space/my-website",
      "created": "2026-01-17T10:30:00Z",
      "attached": false,
      "lastActivity": "2026-01-17T14:22:00Z"
    }
  ]
}

GET /api/sessions/:id
Response: { ...single session... }
404 if not found

GET /api/sessions/:id/content
Response: {
  "sessionId": "my-website",
  "content": "$ claude\n\nWelcome to Claude Code...\n\n> ",
  "timestamp": "2026-01-17T14:22:33Z"
}

POST /api/sessions/:id/submit
Body: { "text": "Fix the login bug" }
Response: 200 OK (empty body)
- Creates session if doesn't exist (lazy init)
- Errors if project has no git initialized

POST /api/sessions/:id/keys
Body: { "key": "Down" }  // or "Up", "Enter", "Escape", "CtrlC", etc.
Response: 200 OK (empty body)
- Sends special key sequences for interactive prompts
- Used for arrow key navigation, Enter to confirm, Ctrl+C to cancel
- Supported keys: Up, Down, Left, Right, Enter, Escape, Tab, Backspace, CtrlC, CtrlD, CtrlZ

DELETE /api/sessions/:id
Response: 204 No Content
- Kills the tmux session
```

### Phase 4: WebSocket Streaming

#### 4.1 WebSocket Route

```
WS /api/sessions/:id/stream?token=<auth_token>
```

- [ ] Authenticate via query param token
- [ ] Verify session exists (or create on first message?)
- [ ] Start polling tmux capture-pane at interval (e.g., 500ms)
- [ ] Send content updates to client
- [ ] Detect changes to avoid sending duplicates (hash comparison)
- [ ] Handle client disconnect (clean up interval)

Message format (server → client):
```json
{
  "type": "content",
  "data": {
    "content": "...",
    "timestamp": "2026-01-17T14:22:33Z"
  }
}
```

Message format (client → server):
```json
{
  "type": "input",
  "data": {
    "text": "Fix the bug",
    "submit": true
  }
}
```

### Phase 5: Claude Code Integration

#### 5.1 Starting Claude Code in Sessions
- [ ] When session is created, run `claude` command
- [ ] Handle Claude Code not being installed (clear error message)
- [ ] Configure Claude Code to use the project directory

#### 5.2 Git Workflow Enforcement

Before allowing code changes, verify:
```bash
# Check git exists
[ -d "$PROJECT_PATH/.git" ]

# Check current branch
git -C "$PROJECT_PATH" branch --show-current

# If on main/master, agent should create branch
# (This is enforced by Claude Code's CLAUDE.md, not the API)
```

The API's role:
- [ ] Report `hasGit` status in project info
- [ ] Report current `gitBranch` in project info
- [ ] Return error on submit if project has no git
- [ ] Do NOT enforce branch rules (that's Claude Code's job via CLAUDE.md)

#### 5.3 CLAUDE.md Generation

When a session is created for a project, ensure a `CLAUDE.md` exists with rules:
- [ ] Check if `CLAUDE.md` exists in project root
- [ ] If not, create one with git workflow rules:

```markdown
# Project Rules

## Git Workflow
- NEVER commit directly to main or master
- Create a branch before making changes: `claude/<description>`
- NEVER merge branches - leave that to humans
- Always commit your changes before stopping
```

### Phase 6: Error Handling & Robustness

#### 6.1 Error Responses
- [ ] Consistent error response format:
  ```json
  {
    "error": {
      "code": "SESSION_NOT_FOUND",
      "message": "Session 'xyz' does not exist"
    }
  }
  ```
- [ ] Error codes:
  - `AUTH_REQUIRED` - Missing auth token
  - `AUTH_INVALID` - Invalid auth token
  - `PROJECT_NOT_FOUND` - Project doesn't exist
  - `SESSION_NOT_FOUND` - Session doesn't exist
  - `GIT_NOT_INITIALIZED` - Project has no git
  - `TMUX_ERROR` - tmux command failed
  - `INTERNAL_ERROR` - Unexpected error

#### 6.2 Logging
- [ ] Request logging (method, path, status, duration)
- [ ] tmux command logging (for debugging)
- [ ] Error logging with stack traces

#### 6.3 Process Management
- [ ] Handle SIGTERM/SIGINT gracefully
- [ ] Clean up WebSocket connections on shutdown
- [ ] Consider: kill managed sessions on shutdown? (Probably not - let them persist)

### Phase 7: Development & Deployment

#### 7.1 Development
- [ ] Hot reload with tsx watch
- [ ] Create sample projects in workspace for testing
- [ ] Test scripts for common operations

#### 7.2 Deployment (Local)
- [ ] systemd/launchd service file for auto-start
- [ ] Or run inside tmux itself for persistence
- [ ] Document Tailscale setup

#### 7.3 Documentation
- [ ] `api/README.md` with:
  - Setup instructions
  - Configuration options
  - API endpoint documentation
  - Troubleshooting guide

## API Reference Summary

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/health` | Health check |
| GET | `/api/info` | Server info |
| GET | `/api/projects` | List all projects |
| GET | `/api/projects/:name` | Get project details |
| GET | `/api/sessions` | List active sessions |
| GET | `/api/sessions/:id` | Get session details |
| GET | `/api/sessions/:id/content` | Get terminal content |
| POST | `/api/sessions/:id/keys` | Send special keys (arrows, Enter, Ctrl+C) |
| POST | `/api/sessions/:id/submit` | Send text input (creates session if needed) |
| DELETE | `/api/sessions/:id` | Kill session |
| WS | `/api/sessions/:id/stream` | Real-time terminal stream |

## Testing Strategy

- **Unit Tests**: Services with mocked exec
- **Integration Tests**: Real tmux operations (in CI with tmux installed)
- **Manual Testing**: curl scripts for each endpoint

## Dependencies

```json
{
  "dependencies": {
    "fastify": "^4.x",
    "@fastify/websocket": "^8.x",
    "@fastify/cors": "^8.x",
    "zod": "^3.x",
    "yaml": "^2.x",
    "dotenv": "^16.x"
  },
  "devDependencies": {
    "typescript": "^5.x",
    "@types/node": "^20.x",
    "tsx": "^4.x"
  }
}
```

## Notes for Implementation Team

1. **tmux must be installed** - Check on startup and fail fast with clear message
2. **File paths are absolute** - Always use absolute paths for workspace/projects
3. **Session names = project names** - Keep this 1:1 mapping simple
4. **Don't over-engineer auth** - Single bearer token is fine for personal use
5. **WebSocket is optional** - Polling fallback should always work
6. **Test with real Claude Code** - Mock responses won't catch real issues

## Open Questions

1. Should we support multiple panes per session?
2. Rate limiting needed for submit endpoint?
3. Should `/submit` wait for Claude to respond before returning?
4. Persist session list across API restarts? (tmux persists anyway)
