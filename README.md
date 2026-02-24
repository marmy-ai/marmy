# Marmy

Remote tmux + Claude Code mobile client. Run Claude Code on your laptop, continue the conversation from your phone.

Marmy is a React Native mobile app paired with a lightweight Rust daemon that bridges tmux sessions to your phone over a secure network. It provides a raw terminal view (xterm.js), a rich view that understands markdown and code blocks, and a read-only file browser — all connected to your remote tmux sessions in real time.

## Architecture

```
  Phone (React Native)                    Laptop / Server
  ┌──────────────────┐                   ┌─────────────────────┐
  │  Machines Tab    │                   │  marmy-agent (Rust) │
  │  Sessions Tab    │◄── WebSocket ───► │    │                │
  │  Terminal Tab    │    + REST API      │    ├─ tmux -CC      │
  │  Files Tab       │                   │    │  (control mode) │
  └──────────────────┘                   │    ├─ REST API       │
         │                               │    └─ File server    │
         │                               └─────────────────────┘
         └── Tailscale / LAN / VPN ──────────────┘
```

**marmy-agent** runs on each development machine. It connects to the local tmux server via [control mode](https://github.com/tmux/tmux/wiki/Control-Mode) (`tmux -CC`) and exposes a WebSocket + REST API. The mobile app connects to the agent and gets real-time terminal output, session topology, and file access.

## Prerequisites

### On your development machine (server)

- **Rust** 1.75+ (`curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh`)
- **tmux** 3.2+ (`apt install tmux` / `brew install tmux`)

### On your phone

- **Expo Go** app ([iOS](https://apps.apple.com/app/expo-go/id982107779) / [Android](https://play.google.com/store/apps/details?id=host.exp.exponent)) for development
- Or build a standalone binary with `eas build`

### For development (building the mobile app)

- **Node.js** 18+ and npm
- **Expo CLI**: `npm install -g expo-cli`

### Networking

Both devices need IP connectivity. Recommended options:

| Method | Difficulty | Best for |
|--------|-----------|----------|
| **Same LAN** | None | Phone and laptop on same Wi-Fi |
| **Tailscale** | Easy | Phone on cellular, laptop behind NAT |
| **WireGuard** | Medium | Full control, have public IP or VPS |
| **SSH tunnel** | Medium | Already have a VPS |

**Tailscale** (recommended for most users): Install on both devices, sign in, done. Your laptop gets a stable IP like `100.x.y.z` accessible from your phone anywhere.

## Quick Start

### 1. Build and run the agent

```bash
cd agent
cargo build --release

# The binary is at target/release/marmy-agent
# Copy it somewhere on your PATH if desired:
cp target/release/marmy-agent ~/.local/bin/
```

### 2. Start the agent

```bash
marmy-agent serve
```

On first run, this:
1. Creates a config file at `~/.config/marmy/config.toml`
2. Generates a random auth token
3. Connects to tmux via control mode (creates a `_marmy_ctrl` session)
4. Starts listening on `0.0.0.0:9876`

### 3. Get pairing info

```bash
marmy-agent pair
```

This prints your machine's hostname, port, and auth token. You'll enter these in the mobile app.

Example output:
```
=== Marmy Pairing Info ===

Hostname:  my-laptop
Port:      9876
Token:     a1b2c3d4e5f6...

In the Marmy app, add this machine with:
  Address:  my-laptop:9876
  Token:    a1b2c3d4e5f6...
```

### 4. Set up the mobile app

```bash
cd mobile
npm install
npx expo start
```

Scan the QR code with Expo Go on your phone, or press `i` for iOS simulator / `a` for Android emulator.

### 5. Connect from the app

1. Open the **Machines** tab
2. Tap **+** to add a machine
3. Enter a name, the address (`host:port`), and the auth token from step 3
4. Tap the machine card to connect
5. You'll see your tmux sessions in the **Sessions** tab
6. Tap any pane to open it in the **Terminal** tab

## Configuration

The agent config lives at `~/.config/marmy/config.toml`:

```toml
[server]
bind = "0.0.0.0"     # Listen address
port = 9876           # Listen port

[auth]
token = "auto-generated-token"   # Auth token for API access

[files]
allowed_paths = [     # Directories the mobile app can browse
  "~/projects",       # Add your project directories here
  "~/code",
]

[tmux]
socket_name = ""      # tmux socket name (-L flag). Empty = default server
```

### File browsing

File browsing is **disabled by default** for security. To enable it, add directories to `allowed_paths`:

```toml
[files]
allowed_paths = ["~/projects", "/home/me/code"]
```

The agent will only serve files within these directories. Files are read-only (no write access from the mobile app).

## Features

### Machines Tab
- Add/remove machines by address and token
- Connection status indicators
- Long-press to remove a machine

### Sessions Tab
- Live view of all tmux sessions, windows, and panes
- Shows running process name, current directory, and dimensions per pane
- Topology auto-updates when sessions/windows/panes are created or destroyed
- Tap any pane to open in the terminal view

### Terminal Tab
- **Raw mode**: Full terminal emulation via xterm.js in a WebView
  - Proper ANSI rendering, colors, cursor positioning
  - Touch-friendly with scrollback
  - Shortcut bar: Tab, Esc, Ctrl-C, Ctrl-D, arrow keys, quick "y" approve
  - Text input bar for typing commands
- **Rich mode**: Parsed view of terminal output
  - Detects markdown headings and fenced code blocks
  - Renders code blocks with monospace styling
  - Scrollable, formatted text
- Toggle between Raw and Rich with a single tap

### Files Tab
- Browse remote file trees
- Navigate directories with breadcrumb path
- View file contents with line numbers
- Sorted: directories first, then alphabetically
- Hidden files (dotfiles) filtered out

## How It Works

### tmux Control Mode

The agent connects to tmux using [control mode](https://github.com/tmux/tmux/wiki/Control-Mode) (`tmux -CC`). This is the same mechanism iTerm2 uses for its tmux integration. In control mode, tmux sends structured text notifications instead of drawing to a terminal:

- `%output %3 hello\012world` — pane %3 produced output (octal-escaped)
- `%window-add @1` — a new window was created
- `%sessions-changed` — sessions were created/destroyed
- `%begin` / `%end` — command response boundaries

The agent parses these notifications, maintains an in-memory topology model, and broadcasts events to connected mobile clients via WebSocket.

### WebSocket Protocol

A single WebSocket connection (`/ws`) handles all real-time communication:

**Client → Server:**
```json
{"type": "subscribe_pane", "pane_id": "%3"}
{"type": "input", "pane_id": "%3", "keys": "ls -la\n"}
{"type": "resize", "pane_id": "%3", "cols": 80, "rows": 24}
```

**Server → Client:**
```json
{"type": "pane_output", "pane_id": "%3", "data": "..."}
{"type": "topology", "sessions": [...], "windows": [...], "panes": [...]}
```

### REST API

```
GET  /api/sessions              List all sessions/windows/panes
GET  /api/panes/:id/content     Capture current pane screen
GET  /api/panes/:id/history     Capture full scrollback
POST /api/panes/:id/input       Send keys to a pane
POST /api/panes/:id/resize      Resize a pane
GET  /api/files/tree?path=...   List directory contents
GET  /api/files/content?path=.. Read file contents
```

## Running as a Service

### systemd (Linux)

Create `/etc/systemd/system/marmy-agent.service`:

```ini
[Unit]
Description=Marmy Agent
After=network.target

[Service]
Type=simple
User=your-username
ExecStart=/home/your-username/.local/bin/marmy-agent serve
Restart=always
RestartSec=5
Environment=RUST_LOG=marmy_agent=info

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now marmy-agent
sudo systemctl status marmy-agent
```

### launchd (macOS)

Create `~/Library/LaunchAgents/com.marmy.agent.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.marmy.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/marmy-agent</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/marmy-agent.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/marmy-agent.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>RUST_LOG</key>
        <string>marmy_agent=info</string>
    </dict>
</dict>
</plist>
```

```bash
launchctl load ~/Library/LaunchAgents/com.marmy.agent.plist
launchctl list | grep marmy
```

## Networking Setup

### Tailscale (recommended)

1. Install Tailscale on your laptop: https://tailscale.com/download
2. Install Tailscale on your phone: App Store / Play Store
3. Sign in to the same account on both
4. Your laptop gets a Tailscale IP (e.g., `100.64.0.2`)
5. In Marmy, add your machine with address `100.64.0.2:9876`

With MagicDNS enabled, you can use your machine's name instead: `my-laptop:9876`.

### Same LAN

If both devices are on the same Wi-Fi:

```bash
# Find your laptop's local IP
ip addr show | grep "inet " | grep -v 127.0.0.1   # Linux
ifconfig | grep "inet " | grep -v 127.0.0.1        # macOS
```

Use this IP in the Marmy app (e.g., `192.168.1.100:9876`).

### SSH Reverse Tunnel (through a VPS)

If your laptop is behind NAT and you have a VPS:

```bash
# On your laptop: forward port 9876 through the VPS
ssh -R 9876:localhost:9876 user@your-vps.com -N

# In Marmy app, connect to: your-vps.com:9876
```

For persistence, use `autossh`:
```bash
autossh -M 0 -R 9876:localhost:9876 user@your-vps.com \
  -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -N
```

## Firewall

If you have a firewall, allow TCP port 9876 (or your configured port):

```bash
# ufw (Ubuntu)
sudo ufw allow 9876/tcp

# firewalld (Fedora/RHEL)
sudo firewall-cmd --add-port=9876/tcp --permanent
sudo firewall-cmd --reload

# iptables
sudo iptables -A INPUT -p tcp --dport 9876 -j ACCEPT
```

## Troubleshooting

### Agent won't start

**"failed to spawn tmux -CC"**: tmux is not installed or not in PATH.
```bash
which tmux    # Should print a path
tmux -V       # Should be 3.2+
```

**"Address already in use"**: Another process is using port 9876.
```bash
lsof -i :9876               # Find what's using the port
marmy-agent serve -p 9877   # Use a different port
```

### Can't connect from phone

1. Verify the agent is running: `curl http://localhost:9876/api/sessions`
2. Check firewall: `curl http://<agent-ip>:9876/api/sessions` from another machine
3. Check Tailscale: `tailscale status` — both devices should be listed
4. Verify token: the token in the app must exactly match `marmy-agent pair` output

### WebSocket disconnects

The mobile app auto-reconnects with exponential backoff (1s → 2s → 4s → ... → 30s max). If you see frequent disconnects:
- Check network stability (Wi-Fi signal, cellular coverage)
- The agent logs connection events at `info` level: `RUST_LOG=marmy_agent=debug marmy-agent serve`

### No tmux sessions shown

The agent creates a hidden `_marmy_ctrl` session for its control connection. Your actual sessions should appear. If they don't:
- Verify you have tmux sessions: `tmux list-sessions`
- Check if using a non-default tmux socket: set `socket_name` in config

### File browser shows "path not in allowed directories"

File browsing is disabled by default. Edit `~/.config/marmy/config.toml`:
```toml
[files]
allowed_paths = ["~/projects"]
```
Restart the agent after changing config.

## Development

### Agent development

```bash
cd agent
cargo run -- serve                    # Run in dev mode
RUST_LOG=marmy_agent=debug cargo run -- serve  # With debug logging
cargo test                            # Run tests
cargo build --release                 # Release build
```

### Mobile app development

```bash
cd mobile
npm install
npx expo start          # Start dev server
npx expo start --clear  # Clear cache and start
```

## Project Structure

```
marmy/
├── agent/                     # Rust daemon
│   ├── Cargo.toml
│   └── src/
│       ├── main.rs            # CLI entry point (serve, pair, config)
│       ├── config.rs          # TOML config management
│       ├── auth.rs            # Bearer token auth middleware
│       ├── state.rs           # Shared app state (topology cache)
│       ├── tmux/
│       │   ├── types.rs       # Session/Window/Pane types, WS messages
│       │   ├── parser.rs      # Control mode protocol parser
│       │   └── control.rs     # tmux -CC connection manager
│       └── api/
│           ├── mod.rs         # Router setup
│           ├── sessions.rs    # GET /api/sessions
│           ├── panes.rs       # Pane input/content/resize endpoints
│           ├── files.rs       # File tree and content endpoints
│           └── ws.rs          # WebSocket handler
├── mobile/                    # React Native (Expo) app
│   ├── package.json
│   ├── app.json
│   ├── app/                   # expo-router pages
│   │   ├── _layout.tsx        # Root layout
│   │   └── (tabs)/
│   │       ├── _layout.tsx    # Tab bar config
│   │       ├── index.tsx      # Machines screen
│   │       ├── sessions.tsx   # Sessions/panes browser
│   │       ├── terminal.tsx   # Terminal + rich view
│   │       └── files.tsx      # File browser
│   └── src/
│       ├── types/             # TypeScript types (API contract)
│       ├── services/          # API client, WebSocket manager
│       ├── stores/            # Zustand state stores
│       └── components/        # Reusable UI components
│           ├── TerminalView   # xterm.js in WebView
│           ├── RichView       # Markdown/code block renderer
│           ├── FileTree       # Directory listing
│           └── CodeViewer     # Line-numbered code display
├── product_prd.md             # Product requirements document
└── README.md                  # This file
```

## Security

- **Auth**: Bearer token authentication on all API endpoints. Token auto-generated on first run, shown via `marmy-agent pair`.
- **File access**: Explicitly scoped to `allowed_paths` in config. No access by default.
- **Read-only files**: The agent never writes files on behalf of the mobile client.
- **Terminal input**: Only sent to panes the user explicitly selects. No ambient command execution.
- **Transport**: Tailscale provides WireGuard encryption. Within a LAN, traffic is unencrypted HTTP/WS — use Tailscale or a VPN for security over untrusted networks.

## License

MIT
