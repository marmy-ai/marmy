# Marmy

Remote tmux + Claude Code mobile client. Run Claude Code on your laptop, continue the conversation from your phone.

Marmy is a React Native mobile app paired with a lightweight Rust daemon that bridges tmux sessions to your phone over a secure network. It provides a plain-text terminal view with input, shortcut keys, and a read-only file browser — all connected to your remote tmux sessions via polling and REST API.

## Architecture

```
  Phone (React Native)                    Laptop / Server
  ┌──────────────────┐                   ┌─────────────────────┐
  │  Machines Tab    │                   │  marmy-agent (Rust) │
  │  Sessions Tab    │◄── REST API ────► │    │                │
  │  Terminal Tab    │    + WebSocket     │    ├─ tmux -CC      │
  │  Files Tab       │    (topology)      │    │  (control mode) │
  └──────────────────┘                   │    ├─ REST API       │
         │                               │    └─ File server    │
         │                               └─────────────────────┘
         └── Tailscale / LAN / VPN ──────────────┘
```

**marmy-agent** runs on each development machine. It connects to the local tmux server via [control mode](https://github.com/tmux/tmux/wiki/Control-Mode) (`tmux -CC`) and exposes a REST API (with an optional WebSocket for topology updates). The mobile app polls pane content via REST and sends input via REST POST — simple, reliable, and easy to debug.

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
- Plain-text terminal view — polls pane content via REST every 500ms
- Monospace font, auto-scroll to bottom on new output
- Text input bar for typing commands (sent via REST POST)
- Shortcut bar: Ctrl-C, Tab, Up, Down, y, n
- Selectable text for copy/paste

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

The agent parses these notifications and maintains an in-memory topology model.

### REST API (primary)

The mobile app uses REST for all core operations — polling pane content, sending input, browsing files. This is simple, stateless, and easy to debug with `curl`.

```
GET  /api/sessions              List all sessions/windows/panes
GET  /api/panes/:id/content     Capture current pane screen (plain text)
GET  /api/panes/:id/history     Capture full scrollback
POST /api/panes/:id/input       Send keys to a pane (hex-encoded via send-keys -H)
POST /api/panes/:id/resize      Resize a pane
GET  /api/files/tree?path=...   List directory contents
GET  /api/files/content?path=.. Read file contents
```

### WebSocket (optional)

A WebSocket endpoint (`/ws`) is available for real-time topology updates (session/window/pane changes) and streaming pane output. The mobile app currently uses REST polling for terminal content, but the WebSocket can be used for lower-latency use cases.

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

Tailscale is the easiest way to connect your phone to your development machine from anywhere. It creates a WireGuard-encrypted mesh VPN that works through NAT, firewalls, and cellular networks — no port forwarding, no public IPs, no configuration headaches. Traffic between your devices is end-to-end encrypted, so even though Marmy uses plain HTTP, the transport layer is fully secured.

**The short version:** install Tailscale on both devices, sign in, use your Tailscale IP in the Marmy app. That's it — everything else below is optional hardening.

#### Step 1: Install Tailscale on your development machine

**macOS:**
```bash
# Homebrew
brew install --cask tailscale

# Or download from https://tailscale.com/download/mac
# The Mac app lives in the menu bar
```

**Linux (Debian/Ubuntu):**
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**Linux (Fedora/RHEL):**
```bash
sudo dnf install -y tailscale
sudo systemctl enable --now tailscaled
sudo tailscale up
```

After installation, authenticate when prompted. Your machine joins your tailnet and gets a stable IP in the `100.x.y.z` range.

#### Step 2: Install Tailscale on your phone

- **iOS**: [Tailscale on the App Store](https://apps.apple.com/app/tailscale/id1470499037)
- **Android**: [Tailscale on Google Play](https://play.google.com/store/apps/details?id=com.tailscale.ipn)

Open the app, sign in with the same account (or accept an invite to the same tailnet). Your phone now has its own Tailscale IP and can reach your development machine directly.

#### Step 3: Find your Tailscale IP

```bash
# On your development machine
tailscale ip -4
# Example output: 100.89.137.42
```

Or check the Tailscale admin console at https://login.tailscale.com/admin/machines.

#### Step 4: Connect from Marmy

In the Marmy app, add your machine with:
- **Address**: `100.89.137.42:9876` (your Tailscale IP)
- **Token**: from `marmy-agent pair`

That's all you need. Your phone can now reach the agent from anywhere — home Wi-Fi, coffee shop, cellular, wherever.

#### MagicDNS (friendly hostnames)

Tailscale includes [MagicDNS](https://tailscale.com/kb/1081/magicdns), which is enabled by default on new tailnets. It lets you use your machine's hostname instead of an IP:

```
my-macbook:9876
dev-server:9876
```

Check your tailnet name in the admin console under DNS. The full MagicDNS name is `<hostname>.<tailnet-name>.ts.net`, but the short name works within your tailnet.

To verify MagicDNS is working:
```bash
# From your phone's Tailscale app, or from another machine on your tailnet
ping my-macbook    # Should resolve to 100.x.y.z
```

#### Hardening: bind only to Tailscale

By default, `marmy-agent` listens on `0.0.0.0` (all interfaces), meaning anything that can reach port 9876 on any interface can attempt to connect (they'd still need the token). If you want to lock it down so the agent *only* accepts connections over Tailscale:

```toml
# ~/.config/marmy/config.toml
[server]
bind = "100.89.137.42"   # Your Tailscale IP — only accepts connections via tailnet
port = 9876
```

Or use the CLI override:
```bash
marmy-agent serve -b 100.89.137.42
```

This means the agent won't respond on your LAN IP, localhost, or any other interface — only Tailscale. Useful if you're on a shared or untrusted network.

> **Tip:** Your Tailscale IP is stable across reboots and network changes, so this config is set-and-forget.

#### Tailscale ACLs (multi-user tailnets)

If you share your tailnet with others (family, team), you can use [Tailscale ACLs](https://tailscale.com/kb/1018/acls) to restrict who can reach the agent. In the admin console under Access Controls:

```jsonc
{
  "acls": [
    {
      // Only your devices can reach the marmy-agent port
      "action": "accept",
      "src": ["your-email@example.com"],
      "dst": ["your-macbook:9876"]
    }
  ]
}
```

This ensures that even other authenticated devices on your tailnet can't connect to the agent.

#### Tailscale HTTPS (optional)

Tailscale can provision TLS certificates for your machines via `tailscale cert`. Marmy doesn't natively serve HTTPS, but you can put a reverse proxy in front if you want TLS termination:

```bash
# Get a cert for your machine
tailscale cert my-macbook.tailnet-name.ts.net

# Use with caddy, nginx, etc. to proxy to localhost:9876
# This is optional — Tailscale's WireGuard tunnel is already encrypted
```

For most users this is unnecessary since WireGuard already encrypts all traffic between your devices. TLS on top would be double encryption.

#### Troubleshooting Tailscale

**Devices not seeing each other:**
```bash
tailscale status                    # Both devices should be listed
tailscale ping <other-device>      # Test direct connectivity
```

**Connection refused:**
```bash
# Verify agent is running and listening
curl http://100.89.137.42:9876/api/sessions -H "Authorization: Bearer <token>"
```

**Tailscale on but no connection:**
- Check that Tailscale is active on your phone (VPN icon should be visible)
- On iOS, Tailscale can be killed by the OS in the background — open the app to re-activate
- On Linux, ensure `tailscaled` is running: `sudo systemctl status tailscaled`

**MagicDNS not resolving:**
- Verify MagicDNS is enabled in admin console → DNS settings
- Try the full name: `my-macbook.tailnet-name.ts.net:9876`
- Fall back to the IP: `tailscale ip -4`

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

### Building for iOS (run on your iPhone via Xcode)

#### Prerequisites

- An [Apple Developer account](https://developer.apple.com/) ($99/year)
- Xcode installed with a valid signing team configured

#### Steps

```bash
cd mobile

# Install JS dependencies
npm install

# Generate the native ios/ project
npx expo prebuild --platform ios

# Install CocoaPods
cd ios && pod install && cd ..

# Open the Xcode workspace
open ios/marmy.xcworkspace
```

In a separate terminal, start the Metro bundler (keep it running):

```bash
cd mobile
npx expo start
```

In Xcode:

1. Select your **signing team** under **Signing & Capabilities** for the `Marmy` target.
2. Connect your iPhone via USB and select it as the build destination.
3. Press **Cmd+R** (or **Product > Run**) to build and install directly on your device.

> **Note:** Debug builds load JS from the Metro bundler, so Metro must be running on the same network as your phone. If you want a standalone build that doesn't need Metro, switch the Xcode scheme to **Release** (**Product > Scheme > Edit Scheme > Run > Build Configuration > Release**).

To create an archive for App Store / TestFlight distribution:

1. Set the device to **Any iOS Device (arm64)**.
2. **Product > Archive**.
3. When the archive finishes, the Organizer opens. Click **Distribute App > App Store Connect > Upload**.
4. Go to [App Store Connect](https://appstoreconnect.apple.com/), fill in listing metadata, and submit for review.

The `ios/` directory retains your signing team and provisioning profile across builds. If you ever need to regenerate the native project (`npx expo prebuild --platform ios --clean`), you'll need to re-select your signing team in **Signing & Capabilities** afterward.

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
│   │       ├── terminal.tsx   # Plain-text terminal (polling)
│   │       └── files.tsx      # File browser
│   └── src/
│       ├── types/             # TypeScript types (API contract)
│       ├── services/          # API client, WebSocket manager
│       ├── stores/            # Zustand state stores
│       └── components/        # Reusable UI components
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
