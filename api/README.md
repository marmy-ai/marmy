# Marmy API

Local HTTP server that manages tmux sessions running Claude Code agents. Exposes a REST API + WebSocket for the iOS client to interact with sessions remotely via Tailscale VPN.

## Prerequisites

- Node.js 20+
- tmux 3.0+
- Claude Code CLI installed and configured
- Tailscale (for remote access)

## Installation

```bash
cd api
npm install
```

## Configuration

### Environment Variables

Create a `.env` file or set these environment variables:

```bash
# Required: Set a secure auth token
MARMY_AUTH_TOKEN=your-secret-token-here

# Optional overrides
MARMY_HOST=0.0.0.0              # Listen address
MARMY_PORT=3000                  # Listen port
MARMY_WORKSPACE_PATH=/path/to/workspace  # Override workspace directory
```

### Config File

Default configuration is in `config/default.yaml`:

```yaml
server:
  host: "0.0.0.0"
  port: 3000

auth:
  token: "change-me-in-env"  # Always override via MARMY_AUTH_TOKEN

workspace:
  path: "/Users/mharajli/Desktop/agent_space"
  exclude:
    - "marmy"  # Exclude this project from sessions

tmux:
  captureLines: 1000
  shell: "/bin/zsh"

claude:
  command: "claude"
```

## Running the Server

```bash
# Development (with hot reload)
npm run dev

# Production
npm run build
npm start
```

## Tailscale Setup

To access Marmy from your iOS device over Tailscale:

### 1. Install Tailscale on Your Laptop

```bash
# macOS (via Homebrew)
brew install tailscale

# Or download from https://tailscale.com/download
```

### 2. Start Tailscale and Log In

```bash
# Start the Tailscale daemon
sudo tailscaled &

# Authenticate
tailscale up
```

Follow the authentication URL to log in with your Tailscale account.

### 3. Get Your Tailscale IP

```bash
tailscale ip -4
# Example output: 100.64.0.1
```

### 4. Configure Marmy to Listen on Tailscale

Option A: Listen on all interfaces (default)
```bash
# The default config listens on 0.0.0.0, which includes Tailscale
MARMY_AUTH_TOKEN=your-secret-token npm run dev
```

Option B: Listen only on Tailscale interface (more secure)
```bash
# Replace with your actual Tailscale IP
MARMY_HOST=100.64.0.1 MARMY_AUTH_TOKEN=your-secret-token npm run dev
```

### 5. Install Tailscale on iOS

1. Download Tailscale from the App Store
2. Log in with the same account as your laptop
3. Enable the VPN connection

### 6. Connect from iOS

Your Marmy server is now accessible at:
```
http://100.64.0.1:3000
```

Use this URL in the Marmy iOS app settings.

### 7. (Optional) Run as a Background Service

To keep the server running when you close the terminal:

**Using tmux:**
```bash
tmux new-session -d -s marmy-api "cd /path/to/marmy/api && MARMY_AUTH_TOKEN=your-token npm start"
```

**Using launchd (macOS):**

Create `~/Library/LaunchAgents/com.marmy.api.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.marmy.api</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/node</string>
        <string>/Users/mharajli/Desktop/agent_space/marmy/api/dist/index.js</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/mharajli/Desktop/agent_space/marmy/api</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>MARMY_AUTH_TOKEN</key>
        <string>your-secret-token</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/marmy-api.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/marmy-api.err</string>
</dict>
</plist>
```

Load the service:
```bash
launchctl load ~/Library/LaunchAgents/com.marmy.api.plist
```

## API Reference

All endpoints except `/api/health` require authentication via Bearer token:
```
Authorization: Bearer your-secret-token
```

### System

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/health` | Health check (no auth required) |
| GET | `/api/info` | Server info (version, hostname, workspace) |

### Projects

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/projects` | List all projects in workspace |
| GET | `/api/projects/:name` | Get project details |

### Sessions

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/sessions` | List active tmux sessions |
| GET | `/api/sessions/:id` | Get session details |
| GET | `/api/sessions/:id/content` | Get terminal content |
| POST | `/api/sessions/:id/submit` | Send input to session (creates if needed) |
| DELETE | `/api/sessions/:id` | Kill session |
| WS | `/api/sessions/:id/stream?token=...` | Real-time terminal stream |

### Example Requests

```bash
# Health check
curl http://100.64.0.1:3000/api/health

# List projects
curl -H "Authorization: Bearer your-token" \
  http://100.64.0.1:3000/api/projects

# Submit to a session (creates session if needed)
curl -X POST \
  -H "Authorization: Bearer your-token" \
  -H "Content-Type: application/json" \
  -d '{"text": "Fix the login bug"}' \
  http://100.64.0.1:3000/api/sessions/my-project/submit

# Get session content
curl -H "Authorization: Bearer your-token" \
  http://100.64.0.1:3000/api/sessions/my-project/content

# Kill a session
curl -X DELETE \
  -H "Authorization: Bearer your-token" \
  http://100.64.0.1:3000/api/sessions/my-project
```

### WebSocket Streaming

Connect to `/api/sessions/:id/stream?token=your-token` for real-time updates.

**Server messages:**
```json
{
  "type": "content",
  "data": {
    "content": "terminal output here...",
    "timestamp": "2026-01-17T14:22:33Z"
  }
}
```

**Client messages:**
```json
{
  "type": "input",
  "data": {
    "text": "your input here",
    "submit": true
  }
}
```

## Error Responses

All errors follow this format:
```json
{
  "error": {
    "code": "ERROR_CODE",
    "message": "Human readable message"
  }
}
```

Error codes:
- `AUTH_REQUIRED` - Missing auth token
- `AUTH_INVALID` - Invalid auth token
- `PROJECT_NOT_FOUND` - Project doesn't exist
- `SESSION_NOT_FOUND` - Session doesn't exist
- `GIT_NOT_INITIALIZED` - Project has no git (required for Claude Code)
- `TMUX_ERROR` - tmux command failed
- `INTERNAL_ERROR` - Unexpected error

## Troubleshooting

### Server won't start

1. Check tmux is installed: `which tmux`
2. Check Node.js version: `node --version` (need 20+)
3. Check port isn't in use: `lsof -i :3000`

### Can't connect from iOS

1. Verify Tailscale is running on both devices
2. Check both devices are on the same Tailnet
3. Ping the laptop from iOS: `ping 100.64.0.1`
4. Verify the server is listening: `curl http://100.64.0.1:3000/api/health`

### Sessions not creating

1. Verify the project exists in the workspace directory
2. Ensure git is initialized in the project: `git init`
3. Check Claude Code is installed: `which claude`

### WebSocket disconnects

- The server polls tmux every 500ms; high latency connections may experience delays
- Check Tailscale connection stability
- Review server logs for errors
