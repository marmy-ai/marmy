# Marmy: Remote tmux + Claude Code Mobile Client

## Product Requirements Document

### Vision

A React Native mobile app that lets developers interact with tmux sessions on remote machines from their phone. The primary use case: run Claude Code on your laptop, then kick back on the couch and continue the conversation from your phone — with rich markdown rendering, syntax-highlighted code viewing, and full terminal interactivity.

Think of it as a remote Claude Code client crossed with a read-only mobile IDE.

---

## Problem Statement

Developers using Claude Code (or any terminal-based AI coding tool) are tethered to their desk. There's no good way to:

1. Monitor long-running Claude Code sessions from a phone
2. Continue a Claude Code conversation from the couch
3. View code changes Claude made with proper syntax highlighting on mobile
4. Manage multiple terminal sessions across machines from a single mobile interface

Existing solutions (Termius, Blink Shell, etc.) give you raw SSH terminals but don't understand the structured output that AI coding tools produce. You get walls of ANSI escape codes instead of beautifully rendered markdown and code.

---

## Target User

Developers who:
- Use Claude Code or similar terminal AI tools daily
- Have one or more machines running tmux sessions
- Want to monitor, review, and interact with those sessions from their phone
- Value rich rendering of markdown and code over raw terminal output

---

## Core Features

### 1. Machine Registry

- Add machines by hostname/IP (or auto-discover via Tailscale)
- Each machine runs a lightweight daemon ("marmy-agent")
- See online/offline status for all registered machines
- Support for naming/grouping machines

### 2. Terminal Session Browser

- List all tmux sessions, windows, and panes per machine
- Custom naming for sessions/panes (persisted client-side)
- Visual indicators: active pane, pane dimensions, running process name
- Quick-jump to any pane with one tap

### 3. Terminal View (Raw Mode)

- Full terminal emulator for direct interaction with tmux panes
- Send keystrokes, including special keys (Ctrl-C, arrow keys, etc.)
- Scrollback buffer access
- Mobile-optimized keyboard with common terminal shortcuts (tab, ctrl, esc, pipe, etc.)

### 4. Rich View (Claude Code Mode)

This is the key differentiator. When a pane is running Claude Code (or similar tools), Marmy can parse the output and render it richly:

- **Markdown blocks**: Rendered with proper formatting (headers, lists, bold, links)
- **Code blocks**: Syntax-highlighted with language detection
- **Diffs**: Rendered as side-by-side or unified diffs with color coding
- **Tool use indicators**: Show which tools Claude is using (file reads, edits, bash commands)
- **Thinking indicators**: Show when Claude is thinking vs. outputting
- Toggle between raw terminal view and rich view at any time

### 5. File Browser (Read-Only IDE)

- Browse the project file tree on the remote machine
- Open files with syntax highlighting (language auto-detection)
- Search within files (grep-like)
- See recent file changes (git diff integration)
- Tap a file reference in Claude's output to jump directly to it

### 6. Input & Interaction

- Text input field for sending messages to Claude Code
- Quick-action buttons: approve tool use (y/n), interrupt (Ctrl-C), scroll
- Voice-to-text input for truly hands-free couch coding
- Clipboard integration for copying code snippets

---

## System Architecture

```
+------------------+       +------------------+       +------------------+
|   Phone App      |       |   Tailscale /    |       |   Dev Machine    |
|   (React Native) | <---> |   WireGuard      | <---> |   (marmy-agent)  |
|                  |       |   Mesh Network   |       |                  |
+------------------+       +------------------+       +------------------+
                                                             |
                                                      +------+------+
                                                      |  tmux server |
                                                      |  + file sys  |
                                                      +-------------+
```

### Three Components

#### 1. marmy-agent (Daemon on each dev machine)

**Language**: Rust or Go (single binary, no runtime dependencies)

**Responsibilities**:
- Connect to the local tmux server via tmux control mode (`tmux -CC`)
- Stream pane output in real-time to connected clients
- Expose session/window/pane topology
- Serve file system contents (read-only, scoped to allowed directories)
- Handle git operations (status, diff, log) for project directories
- Parse Claude Code output into structured segments (markdown, code, tool calls)
- Accept input and relay it to specific panes via `tmux send-keys`
- Authenticate incoming connections (token-based)

**Key Design Decisions**:

- **tmux control mode** is the right abstraction. It provides structured, parseable output with `%`-prefixed notification events for state changes (pane created, pane closed, window renamed, etc.). This is the same mechanism iTerm2 uses for its tmux integration. The agent connects as a control-mode client and gets real-time events without polling.

- **Structured output parsing**: The agent monitors pane output and detects Claude Code's output patterns. Claude Code uses `--output-format stream-json` which emits structured JSON events. The agent can either:
  - (a) Run Claude Code in `stream-json` mode and parse JSON events directly, or
  - (b) Parse the ANSI terminal output heuristically using known Claude Code output patterns (tool call blocks, markdown fences, thinking indicators)

  Option (a) is strongly preferred when possible. For sessions not started by Marmy, option (b) serves as fallback.

- **File serving**: Uses `inotify` (Linux) or `FSEvents` (macOS) to watch for file changes and push notifications to the client. File contents served on demand with range support for large files.

**API Surface** (WebSocket + REST):

```
WebSocket /ws/terminal/{pane_id}     - Real-time pane output stream
WebSocket /ws/events                  - Session/window/pane lifecycle events

GET  /api/sessions                    - List all tmux sessions
GET  /api/sessions/{id}/panes         - List panes in a session
POST /api/panes/{id}/input            - Send input to a pane
POST /api/panes/{id}/resize           - Resize a pane
GET  /api/panes/{id}/history          - Get scrollback buffer
GET  /api/panes/{id}/structured       - Get parsed rich output

GET  /api/files/tree?path=...         - Directory listing
GET  /api/files/content?path=...      - File contents
GET  /api/files/search?q=...&path=... - Search within files

GET  /api/git/status?repo=...         - Git status
GET  /api/git/diff?repo=...           - Git diff
```

#### 2. Networking Layer

**Recommended: Tailscale**

Tailscale is the clear choice for the networking layer:

- **Zero-config NAT traversal**: Works through CGNAT, hotel Wi-Fi, cellular networks — critical when your phone is on mobile data and your laptop is on home Wi-Fi
- **Automatic peer-to-peer connections**: Direct connections (no relay) for >90% of cases, meaning latency equals raw WireGuard
- **DERP relay fallback**: When direct connection fails, Tailscale relays through encrypted DERP servers (adds ~20-50ms, acceptable for terminal use)
- **MagicDNS**: Access machines by name (`laptop.tailnet`) instead of IP
- **ACLs**: Fine-grained access control if sharing machines with a team
- **Mobile SDK**: First-class iOS and Android support

**Alternative options** (in order of preference):
1. **Headscale** (self-hosted Tailscale coordination server) — for users who want full control
2. **Raw WireGuard** — if both devices have stable IPs or a relay VPS
3. **Cloudflare Tunnel** — alternative for HTTP-based transport
4. **Self-hosted relay server** — WebSocket relay running on a VPS, as last resort

**Why not SSH?**: SSH works but gives you a raw byte stream. You'd need to layer your own protocol on top anyway. The agent approach with WebSocket gives you structured communication from the start.

#### 3. Phone App (React Native)

**Framework**: React Native with Expo (for build tooling and OTA updates)

**State Management**: Zustand (lightweight, minimal boilerplate)

**Navigation**: React Navigation (tab-based: Machines > Sessions > Terminal/Rich/Files)

##### Terminal Rendering

**Approach: xterm.js in a WebView**

There is no mature native React Native terminal emulator. The proven approach is:

1. Bundle a lightweight HTML page with xterm.js
2. Render it inside `react-native-webview`
3. Bridge WebSocket data between the RN app and the WebView via `postMessage`/`onMessage`
4. The xterm.js instance handles all ANSI rendering, cursor positioning, scrollback

This is the same approach used by production mobile SSH apps (Pisth, etc.).

**xterm.js addons to include**:
- `xterm-addon-fit` — auto-resize to container
- `xterm-addon-web-links` — clickable URLs
- `xterm-addon-search` — search scrollback
- `xterm-addon-unicode11` — proper Unicode rendering

**Custom keyboard bar**: A floating bar above the system keyboard with:
- `Tab`, `Esc`, `Ctrl`, `Alt` modifier keys
- Arrow keys (up/down/left/right)
- Common symbols: `|`, `~`, `/`, `\`, `-`, `_`
- Programmable quick buttons (e.g., "y\n" for approving Claude tool use)

##### Markdown Rendering

**Library**: `react-native-marked` (powered by marked.js)

Chosen over alternatives because:
- Built-in theming support with dark mode
- Custom renderer class allows overriding any element
- Active maintenance
- Better performance than `react-native-markdown-display` for large documents

For code blocks within markdown, use `react-native-syntax-highlighter` (Prism-based) as a custom renderer for fenced code blocks. This gives you proper syntax highlighting for 200+ languages.

##### Code Viewer (Read-Only IDE)

**Approach: CodeMirror 6 in a WebView**

CodeMirror 6 over Monaco because:
- Monaco officially does not support mobile browsers/WebViews
- CodeMirror 6 was designed with mobile support in mind
- Better touch interaction (scrolling, selection)
- Smaller bundle size
- Excellent language support via `@codemirror/lang-*` packages

The code viewer WebView loads CodeMirror 6 configured as read-only with:
- Syntax highlighting (language auto-detected from file extension)
- Line numbers
- Code folding
- Search (Ctrl+F / Cmd+F)
- Minimap (optional)
- Dark/light theme matching the app

File tree navigation uses a native React Native component (`react-native-collapsible-tree` or custom FlatList-based tree) for performance.

##### Rich View Architecture

The "Rich View" is the core innovation. It sits between raw terminal and a fully custom UI:

```
                      +------ Raw Terminal (xterm.js WebView)
                      |
Pane Output -----> Router
                      |
                      +------ Rich View (native RN components)
                                |
                                +-- Markdown blocks -> react-native-marked
                                +-- Code blocks -> react-native-syntax-highlighter
                                +-- Diffs -> custom diff component
                                +-- Tool calls -> custom card component
                                +-- Text -> styled Text component
```

The agent on the machine parses Claude Code's output stream and emits structured segments:

```json
{
  "segments": [
    { "type": "text", "content": "I'll help you fix that bug." },
    { "type": "markdown", "content": "## Changes needed\n\n1. Fix the null check\n2. Add error handling" },
    { "type": "code", "language": "typescript", "content": "function fix() { ... }", "file": "src/utils.ts", "line": 42 },
    { "type": "diff", "file": "src/utils.ts", "hunks": [...] },
    { "type": "tool_call", "tool": "Edit", "status": "completed", "file": "src/utils.ts" },
    { "type": "thinking", "active": true }
  ]
}
```

The app renders each segment with the appropriate component. Users can tap code references to jump to the file browser, tap diffs to see full context, etc.

---

## Technology Stack Summary

| Component | Technology | Rationale |
|---|---|---|
| **Phone App Framework** | React Native + Expo | Cross-platform, OTA updates, large ecosystem |
| **Terminal Emulator** | xterm.js in WebView | Only production-proven approach for mobile |
| **Markdown Rendering** | react-native-marked | Active, themeable, custom renderers |
| **Code Syntax Highlighting** | react-native-syntax-highlighter (Prism) | Native RN component, 200+ languages |
| **Code Viewer** | CodeMirror 6 in WebView | Mobile-friendly, lighter than Monaco |
| **State Management** | Zustand | Minimal boilerplate, good DX |
| **Navigation** | React Navigation | Standard for RN, tab + stack |
| **Networking** | Tailscale | Zero-config NAT traversal, P2P, mobile SDK |
| **Agent Daemon** | Rust (tokio + axum) | Single binary, fast, low memory, great WebSocket support |
| **tmux Interface** | tmux control mode (-CC) | Structured events, real-time, same as iTerm2 uses |
| **Agent Output Parsing** | tree-sitter + custom parser | Detect markdown fences, code blocks, ANSI patterns |
| **File Watching** | notify (Rust crate) | Cross-platform inotify/FSEvents/kqueue |
| **Auth** | Ed25519 keypair + token exchange | Simple, no external dependencies |
| **Data Transport** | WebSocket (structured JSON) | Real-time bidirectional, low overhead |

---

## Agent Daemon: Detailed Design (Rust)

### Why Rust

- Single static binary — `scp` it to any machine and run, no runtime needed
- Memory-safe with zero-cost abstractions
- `tokio` async runtime handles thousands of concurrent WebSocket connections
- `axum` web framework is ergonomic and fast
- The `portable-pty` or `tmux` control mode integration is straightforward
- Cross-compilation to Linux (x86_64, aarch64) and macOS (x86_64, aarch64)

### Key Crates

```toml
[dependencies]
tokio = { version = "1", features = ["full"] }
axum = { version = "0.8", features = ["ws"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
notify = "7"                    # File watching (inotify/FSEvents)
strip-ansi-escapes = "0.2"     # ANSI code stripping
tree-sitter = "0.24"           # Parsing structured output
git2 = "0.19"                  # Git operations (libgit2 bindings)
tokio-tungstenite = "0.24"     # WebSocket support
tracing = "0.1"                # Structured logging
```

### tmux Control Mode Integration

```
Agent starts:
  1. Spawns `tmux -CC attach -t <target>` (or `new-session` if none exists)
  2. Reads stdout line-by-line
  3. Lines starting with `%` are parsed as control events:
     - %begin / %end / %error — command output boundaries
     - %output %<pane_id> <data> — pane output (real-time)
     - %session-changed / %window-add / %window-close — topology changes
     - %pane-mode-changed — pane state changes
  4. Non-% lines within %begin/%end blocks are command responses
  5. Agent maintains in-memory model of session/window/pane topology
  6. On client connect, sends full state snapshot + subscribes to events
```

### Claude Code Output Parser

The parser runs as a streaming state machine on pane output:

```
States:
  NORMAL          — regular terminal output
  IN_CODE_BLOCK   — inside ``` fenced code block
  IN_TOOL_CALL    — inside a tool use block
  IN_THINKING     — Claude is thinking (spinner/animation detected)
  IN_DIFF         — inside a diff block

Transitions:
  "```" at line start  -> IN_CODE_BLOCK (with language tag)
  "```" at line start while IN_CODE_BLOCK -> NORMAL (emit code segment)
  Tool call patterns   -> IN_TOOL_CALL
  Diff header patterns -> IN_DIFF
  Spinner/loading      -> IN_THINKING
```

For maximum fidelity, the preferred approach is to have the agent launch Claude Code with `--output-format stream-json`, which emits structured JSON events that can be parsed without heuristics. The heuristic parser serves as a fallback for sessions the user started manually before connecting Marmy.

---

## Security Model

### Authentication

1. On first setup, the phone app generates an Ed25519 keypair
2. The user runs `marmy-agent pair` on their machine, which displays a QR code containing:
   - Machine ID
   - One-time pairing token
   - Agent's public key
   - Tailscale IP (if available)
3. Phone scans QR code, exchanges public keys
4. Subsequent connections use mutual authentication (agent verifies phone's signature, phone verifies agent's signature)

### Authorization

- File system access scoped to explicitly allowed directories (configured in `~/.config/marmy/config.toml`)
- No write access to files by default (read-only IDE)
- Terminal input only sent to panes the user explicitly selects
- Rate limiting on input to prevent accidental paste bombs

### Transport Security

- Tailscale provides WireGuard encryption for all traffic
- WebSocket connections additionally use TLS (belt + suspenders)
- No data stored on any intermediate server

---

## Data Flow: End-to-End Example

**Scenario**: User is on couch, wants to ask Claude Code to fix a bug.

```
1. User opens Marmy app on phone
2. App connects to laptop via Tailscale (laptop.tailnet:9876)
3. Agent sends session list: [{ name: "dev", windows: [{ name: "claude", panes: [...] }] }]
4. User taps "claude" pane
5. Agent streams last 1000 lines of pane output (structured)
6. App renders Rich View: Claude's last response with formatted markdown + code
7. User types "Can you fix the null pointer in auth.ts line 42?"
8. App sends: POST /api/panes/%3/input { text: "Can you fix..." }
9. Agent: tmux send-keys -t %3 "Can you fix..." Enter
10. Agent streams Claude's response segments in real-time:
    - { type: "thinking", active: true }
    - { type: "text", content: "I'll fix that..." }
    - { type: "tool_call", tool: "Read", file: "src/auth.ts" }
    - { type: "code", content: "...", language: "typescript" }
    - { type: "diff", file: "src/auth.ts", hunks: [...] }
    - { type: "tool_call", tool: "Edit", status: "pending_approval" }
11. App shows "Edit" tool call card with approve/reject buttons
12. User taps "Approve"
13. App sends: POST /api/panes/%3/input { text: "y" }
14. Agent relays approval, Claude applies the edit
15. User taps file reference "src/auth.ts:42" in the output
16. App opens File Browser, fetches file content, shows CodeMirror view
    scrolled to line 42 with the change highlighted
```

---

## Mobile UX Design

### Navigation Structure

```
Bottom Tabs:
  [Machines] [Sessions] [Terminal] [Files]

Machines Tab:
  - List of registered machines with status indicators
  - Pull-to-refresh, add machine button
  - Tap machine -> navigate to Sessions tab filtered to that machine

Sessions Tab:
  - Grouped by machine, shows tmux sessions/windows/panes
  - Custom names displayed (user-assigned)
  - Running process name shown per pane
  - Tap pane -> navigate to Terminal tab for that pane

Terminal Tab:
  - Toggle: [Raw] [Rich] at top
  - Raw: full xterm.js terminal
  - Rich: parsed output with markdown/code/diffs
  - Input bar at bottom with quick-action buttons
  - Floating shortcut bar above keyboard

Files Tab:
  - File tree on the left (or full-screen on phone)
  - File content with syntax highlighting
  - Search bar at top
  - Breadcrumb navigation
  - Git status indicators (modified, added, deleted)
```

### Mobile-Specific Optimizations

- **Adaptive rendering**: On slow connections, send compressed output and reduce update frequency
- **Offline queue**: Queue input while disconnected, send when reconnected
- **Background notifications**: Alert when Claude finishes a long-running task (via push notification from the agent, using a lightweight push service or Tailscale Funnel webhook)
- **Haptic feedback**: Subtle haptics on tool call approvals, errors
- **Dark mode**: First-class dark mode (most devs prefer it, and it saves battery on OLED)
- **Landscape support**: Terminal view supports landscape for more columns

---

## MVP Scope (v0.1)

Phase 1 — Get the core loop working:

1. **marmy-agent**: Basic daemon that connects to tmux, lists sessions/panes, streams raw output, accepts input
2. **Phone app**: Machine connection (manual IP), session browser, raw terminal view (xterm.js in WebView)
3. **Networking**: Tailscale (user sets up separately), agent listens on a port
4. **Auth**: Simple shared secret / API key (upgrade to keypair later)

Phase 2 — Rich rendering:

5. **Rich View**: Claude Code output parser (heuristic, then stream-json)
6. **Markdown rendering**: Inline markdown blocks
7. **Code highlighting**: Syntax-highlighted code blocks in rich view

Phase 3 — File browsing:

8. **File tree**: Browse remote project files
9. **Code viewer**: CodeMirror 6 read-only viewer
10. **Git integration**: Status, diff, recent commits

Phase 4 — Polish:

11. **QR code pairing**: Secure device pairing
12. **Push notifications**: Background alerts
13. **Voice input**: Voice-to-text for terminal input
14. **Custom keyboard bar**: Terminal shortcut keys
15. **Multi-machine management**: Dashboard view

---

## Open Questions & Risks

### Technical Risks

1. **xterm.js in WebView performance**: Touch scrolling and rendering speed may be poor on lower-end Android devices. Mitigation: benchmark early, consider native terminal renderer if needed.

2. **Claude Code output parsing reliability**: Heuristic parsing of ANSI output is fragile. Claude Code's output format may change between versions. Mitigation: prefer `stream-json` mode, version-pin the parser.

3. **tmux control mode edge cases**: Control mode has known quirks with certain terminal applications (vim, less, etc.) that produce high-volume output. Mitigation: throttle output streaming, implement backpressure.

4. **Tailscale dependency**: Users who can't or won't use Tailscale need an alternative. Mitigation: agent listens on standard WebSocket port, any IP connectivity works.

### Product Risks

1. **"Just use SSH"**: Many developers will question why not just use Termius/Blink. The answer is the rich rendering — but that needs to be immediately impressive to overcome the objection.

2. **Single-player tool**: This is primarily a single-developer tool. Team features (shared sessions, collaborative viewing) could expand the market but add complexity.

3. **Claude Code coupling**: Heavy coupling to Claude Code's output format. Should design the rich parser to be pluggable for other tools (Cursor terminal, Aider, etc.).

---

## Competitive Landscape

| Product | Terminal | Rich Rendering | File Browser | Claude Code Aware | Mobile |
|---|---|---|---|---|---|
| Termius | Full SSH | No | SFTP browser | No | Yes |
| Blink Shell | Full SSH | No | No | No | iOS only |
| VS Code Remote | Full | Yes (built-in) | Yes | No | No (tablet only) |
| Claude.ai web | No | Yes | No | N/A | Yes (web) |
| **Marmy** | **tmux** | **Yes** | **Yes (read-only)** | **Yes** | **Yes** |

Marmy's unique position: the only mobile client that combines terminal access with AI-aware rich rendering and code browsing.

---

## Success Metrics

- **Session engagement**: Average time spent in Rich View vs Raw Terminal (goal: >60% Rich View)
- **Daily active usage**: Developers using Marmy at least once per day
- **Input sent from phone**: Number of Claude Code interactions initiated from the phone (validates the couch-coding use case)
- **Reconnection reliability**: % of sessions that survive network transitions (Wi-Fi -> cellular)
- **Render fidelity**: % of Claude Code output correctly parsed into rich segments (goal: >95%)
