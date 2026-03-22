# Marmy

Manage your Claude Code sessions from your phone.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![iOS Beta](https://img.shields.io/badge/iOS-TestFlight-blue)](https://testflight.apple.com/join/v8HmNu1H)

## What is Marmy

Marmy is a lightweight Rust agent that runs on your machines and an iOS app that connects to it. Together they let you manage your Claude Code sessions (or any tmux terminal agent) from your phone. Read output, send input, browse files, get push notifications, and talk to your agents by voice.

## How it works

The agent runs alongside your terminal sessions. Your phone connects over LAN or Tailscale, authenticated with a token. Everything is self-hosted, open source, and nothing leaves your network.

## Features

- **Session management**: View, create, and control tmux sessions from your phone
- **File browser**: Browse file trees, read code with syntax highlighting, view diffs, markdown, images, and PDFs
- **Push notifications**: Get notified when a Claude Code session finishes or needs input
- **Voice commands**: A Gemini-powered voice assistant relays your spoken decisions to your agents
- **Manager sessions**: Launch a Claude Code session that supervises and coordinates your other sessions
- **Multi-machine support**: Install the agent on each machine and manage them all from one app

## Quick start (macOS)

### 1. Install the agent

Build the macOS menu bar app (MacMarmy), which bundles the agent:

```bash
cd macos/MarmyMenuBar
xcodebuild -scheme MarmyMenuBar -configuration Release build CODE_SIGNING_ALLOWED=NO
open ~/Library/Developer/Xcode/DerivedData/MarmyMenuBar-*/Build/Products/Release/MarmyMenuBar.app
```

Or build the agent standalone:

```bash
cd agent
cargo build --release
cp target/release/marmy-agent ~/.local/bin/
marmy-agent serve
```

### 2. Get the iOS app

Download from [TestFlight](https://testflight.apple.com/join/v8HmNu1H).

### 3. Pair

```bash
marmy-agent pair
```

This prints your machine's hostname, port, and auth token. Enter the address and token in the app.

### 4. Done

Open the Machines tab, tap **+**, enter the address and token, and connect.

## Build from source

### Agent

```bash
git clone https://github.com/marmy-ai/marmy && cd marmy/agent
cargo build --release
./target/release/marmy-agent serve
./target/release/marmy-agent pair
```

### iOS app

```bash
cd mobile
npm install
npx expo prebuild --platform ios
cd ios && pod install && cd ..
open ios/marmy.xcworkspace
```

In Xcode:

1. Select your signing team under Signing & Capabilities for the `Marmy` target.
2. Set the build configuration to **Release**: Product > Scheme > Edit Scheme > Run > Build Configuration > Release.
3. Connect your iPhone and press **Cmd+R** to build and install.

## Configuration

The agent config lives at `~/Library/Application Support/marmy/config.toml` on macOS or `~/.config/marmy/config.toml` on Linux. See [`agent/config.toml.example`](agent/config.toml.example) for all options.

### File browsing

File browsing is **disabled by default**. The default config has `allowed_paths = []`, which means the app cannot browse any files. To enable it, add your project directories:

```toml
[files]
allowed_paths = ["~/projects", "~/code"]
```

The agent will only serve files within these directories. All access is read-only.

### Gemini voice

Add your API key to the config file:

```toml
[voice]
gemini_api_key = "your-key-here"
```

Get a key from [Google AI Studio](https://aistudio.google.com/apikey).

### Push notifications

**TestFlight / App Store builds** use the hosted relay automatically. No configuration needed. The relay URL is set in the default config and routes notifications through a Lambda function.

**Self-built apps** need either:

1. **Your own APNs key**: Create a key in [Apple Developer](https://developer.apple.com) > Keys with APNs enabled. Download the `.p8` file, then configure:

```toml
[notifications]
enabled = true
apns_key_path = "~/.marmy/apns_key.p8"
apns_key_id = "XXXXXXXXXX"
apns_team_id = "XXXXXXXXXX"
apns_topic = "com.marmy.app"
apns_sandbox = true
```

Set `apns_sandbox = true` for dev builds (Xcode), `false` for TestFlight/App Store.

2. **The hosted relay**: If you build the app with the same bundle identifier (`com.marmy.app`), the default relay URL in the config will work. Set a `relay_secret` that matches the relay's `RELAY_SECRET`.

### Tailscale

Install [Tailscale](https://tailscale.com/download) on your machine and phone. The agent binds to `0.0.0.0:9876` by default, so your phone can connect via your machine's Tailscale IP.

```bash
tailscale ip -4
# Use this IP as the address in the Marmy app, e.g. 100.x.y.z:9876
```

To restrict the agent to Tailscale only:

```toml
[server]
bind = "100.x.y.z"  # Your Tailscale IP
port = 9876
```

### Multi-machine

Install the agent on each machine. Run `marmy-agent serve` and `marmy-agent pair` on each one. Add each machine in the app. They all appear in the Machines tab.

## Architecture

```
marmy/
  agent/     Rust agent (REST API + WebSocket, tmux subprocess calls)
  mobile/    iOS app (React Native / Expo)
  macos/     macOS menu bar app (Swift, bundles the Rust agent)
  website/   Landing page (Astro)
  relay/     Push notification relay (Node.js Lambda)
```

The agent interacts with tmux by spawning short-lived subprocess calls (`tmux list-sessions`, `tmux capture-pane`, `tmux send-keys`, etc.) and exposes the results via a REST API. No persistent connection or control mode. The mobile app uses REST for all core operations and an optional WebSocket for real-time topology updates.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

MIT
