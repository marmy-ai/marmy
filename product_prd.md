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
1. **Headscale** — self-hosted Tailscale coordination server, open source, gives full control but loses some features (Funnel, some MagicDNS)
2. **Raw WireGuard** — if both devices have stable IPs or a relay VPS. No NAT traversal; requires port forwarding or a VPS with a public IP
3. **SSH reverse tunnel + autossh** — laptop opens outbound SSH to a VPS, phone connects to VPS. Reliable (`ServerAliveInterval=60`, `ExitOnForwardFailure=yes`) but VPS sees decrypted traffic unless you nest SSH. ~$3-5/month for a VPS
4. **Rathole** (Rust) or **FRP** (Go) — self-hosted reverse proxy/tunnel. Rathole is ~500KB binary with TLS + Noise protocol encryption. FRP has more features (dashboard, P2P mode)
5. **Cloudflare Tunnel** — primarily HTTP-oriented, Cloudflare decrypts at edge (privacy concern for terminal sessions). Not ideal for arbitrary TCP

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

**Tiered approach** — a full editor is overkill for read-only viewing. Use the lightest tool that works:

| File Size | Approach | Rationale |
|---|---|---|
| Small/medium (<5K lines) | `react-native-syntax-highlighter` (native RN) | No WebView overhead, fast render, 185+ languages via Prism/highlight.js |
| Large (>5K lines) | CodeMirror 6 in a WebView (`readOnly: true`) | Virtualized rendering — only draws visible lines, handles million-line files |
| Pre-highlighted (daemon) | Shiki tokens rendered as styled `<Text>` | Zero client-side parsing cost — daemon tokenizes with VS Code TextMate grammars |

**Why NOT Monaco**: Monaco officially does not support mobile browsers/WebViews. Touch interactions (scrolling, selection) are broken. CodeMirror 6 was designed with mobile support — it uses the platform's native selection and editing features on phones.

**CodeMirror 6 configuration** (for the large-file fallback):
- Syntax highlighting (language auto-detected from file extension)
- Line numbers
- Code folding
- Search (Ctrl+F / Cmd+F)
- Dark/light theme matching the app

**Server-side pre-highlighting with Shiki** (optional optimization): The marmy-agent can pre-tokenize files using Shiki (which uses VS Code's TextMate grammars and themes). Tokenized output is sent to the client as structured spans with color metadata, eliminating all client-side parsing. This is especially valuable on slower phones.

File tree navigation uses a native React Native component (custom FlatList-based tree with virtualization) for performance. Git status indicators (modified/added/deleted) shown per-file.

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
| **Code Viewer (small files)** | react-native-syntax-highlighter | Native RN, no WebView, 185+ languages |
| **Code Viewer (large files)** | CodeMirror 6 in WebView | Virtualized rendering, mobile-friendly |
| **State Management** | Zustand | Minimal boilerplate, good DX |
| **Navigation** | React Navigation | Standard for RN, tab + stack |
| **Networking** | Tailscale | Zero-config NAT traversal, P2P, mobile SDK |
| **Agent Daemon** | Rust (tokio + axum) | Single binary, fast, low memory, great WebSocket support |
| **tmux Interface** | tmux control mode (-CC) | Structured events, real-time, same as iTerm2 uses |
| **Agent Output Parsing** | `stream-json` NDJSON (primary) + ANSI heuristic (fallback) | Structured JSON for managed sessions, state-machine parser for attached sessions |
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

The `-CC` variant (double C) disables canonical mode and sends DCS sequences on entry/exit, designed for application integration. This is the same mechanism iTerm2 uses to render tmux panes as native tabs/splits.

**Protocol overview:**

Every command sent via stdin produces an output block:
```
%begin <epoch_seconds> <command_number>
<output lines...>
%end <epoch_seconds> <command_number>
```
(Failed commands replace `%end` with `%error`)

**Asynchronous notifications** (sent outside output blocks, real-time, no polling):

| Event | Format | Description |
|---|---|---|
| `%output` | `%output %<pane_id> <escaped_data>` | Pane produced output. Chars < ASCII 32 and `\` are octal-escaped. |
| `%window-add` | `%window-add @<window_id>` | Window created |
| `%window-close` | `%window-close @<window_id>` | Window destroyed |
| `%window-renamed` | `%window-renamed @<window_id> <name>` | Window renamed |
| `%session-changed` | `%session-changed $<session_id> <name>` | Client attached to different session |
| `%sessions-changed` | `%sessions-changed` | Session created or destroyed |
| `%session-renamed` | `%session-renamed $<session_id> <name>` | Session renamed |
| `%session-window-changed` | `%session-window-changed $<session_id> @<window_id>` | Active window changed |
| `%layout-change` | `%layout-change @<window_id> <layout> <visible_layout> <flags>` | Pane layout changed |
| `%pane-mode-changed` | `%pane-mode-changed %<pane_id>` | Pane entered/exited mode (copy mode, etc.) |
| `%exit` | `%exit [reason]` | Control client exiting |

IDs use `$session`, `@window`, `%pane` prefixes — unique for server lifetime, never reused.

**Subscriptions** (reactive monitoring without polling): `refresh-client -B name:what:format` subscribes to format expressions. When the expanded value changes, a `%subscription-changed` notification fires (at most once per second). Useful for monitoring things like `pane_current_command` changes.

```
Agent lifecycle:
  1. Spawns `tmux -CC attach` (or `new-session`)
  2. Reads stdout line-by-line, parsing %notifications
  3. Builds in-memory model: sessions -> windows -> panes
  4. Subscribes to format expressions for process name changes
  5. On mobile client connect: sends full topology snapshot
  6. Streams %output events to subscribed clients via WebSocket
  7. Relays mobile input via `send-keys -t %<pane_id>`
  8. Uses `capture-pane -t %<id> -p -e -S -` for scrollback history on demand
```

**Supplementary tmux commands** used by the agent:
- `list-sessions -F "#{session_id}:#{session_name}:#{session_windows}"` — structured topology
- `list-panes -a -F "#{pane_id} #{pane_pid} #{pane_current_command} #{pane_current_path} #{pane_width}x#{pane_height}"` — all pane metadata
- `capture-pane -t %3 -p -e -S -` — full scrollback with ANSI codes
- `send-keys -t %3 "text" Enter` — relay input
- `pipe-pane -t %3 -o 'cat >> /tmp/pane.log'` — additional output logging

### Claude Code Output Parsing

Claude Code is built with React + Ink (a React renderer for terminals). Its rendering pipeline converts a React component tree through Yoga (Flexbox layout engine) into a grid of terminal cells, then emits minimal ANSI escape sequences at up to 30fps. Trying to reverse-engineer this ANSI output is fragile. Instead, use the structured output modes.

#### Primary: `--output-format stream-json` (NDJSON)

The preferred approach. Claude Code emits newline-delimited JSON with every event:

```bash
claude -p "your prompt" --output-format stream-json --verbose
```

Event types in the NDJSON stream:

```jsonc
// 1. Init — session metadata and available tools
{"type":"system","subtype":"init","session_id":"...","tools":["Read","Edit","Bash",...]}

// 2. Assistant message — text content and tool calls
{"type":"assistant","message":{"content":[
  {"type":"text","text":"I'll fix that null check in auth.ts..."},
  {"type":"tool_use","id":"toolu_abc","name":"Edit","input":{"file_path":"src/auth.ts",...}}
]}}

// 3. Tool results
{"type":"user","message":{"content":[
  {"type":"tool_result","tool_use_id":"toolu_abc","content":"File edited successfully"}
]}}

// 4. Streaming deltas (with --verbose)
{"type":"stream_event","event":{"delta":{"type":"text_delta","text":"I'll "}}}

// 5. Final result — cost, duration, session ID for --resume
{"type":"result","subtype":"success","duration_ms":108221,"num_turns":12,
 "result":"...","session_id":"...","total_cost_usd":0.57}
```

This gives you **semantic content** — tool calls with names/inputs/results, raw markdown text (not ANSI-rendered), cost tracking, session IDs — without any heuristic parsing.

**Content type routing from stream-json:**

| Content Type | Detection | Mobile Rendering |
|---|---|---|
| Markdown text | `content[].type == "text"` | react-native-marked |
| Code blocks | Parse markdown fences from text | react-native-syntax-highlighter |
| File edits/diffs | `tool_use` with `name == "Edit"` | Custom diff viewer |
| Bash commands | `tool_use` with `name == "Bash"` | Command + output card |
| File reads | `tool_use` with `name == "Read"` | Code viewer link |
| Search results | `tool_use` with `name == "Grep"/"Glob"` | Search results list |
| Cost/usage | `result.total_cost_usd` | Status bar |

#### Fallback: ANSI Heuristic Parser (for pre-existing sessions)

For tmux panes where Claude Code was started manually (not by the agent), fall back to a streaming state machine on the ANSI output:

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

ANSI stripping uses `strip-ansi-escapes` (Rust crate) or `strip-ansi` (npm, 10K+ dependents). For full VT100 state machine parsing, use `node-ansiparser` or `ansi_up` (converts ANSI directly to HTML for WebView rendering).

#### Hybrid Architecture (Recommended)

The agent should support **both modes simultaneously**:

1. **Managed sessions**: Agent launches Claude Code with `--output-format stream-json`. Full structured parsing, maximum fidelity. App gets semantic events.
2. **Attached sessions**: For panes Claude Code is already running in, agent uses tmux control mode `%output` notifications + the heuristic parser. App gets best-effort rich rendering.
3. **Raw passthrough**: Always available. The raw `%output` data feeds an xterm.js WebView for full-fidelity terminal rendering regardless of parsing quality.

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

---

## References

### tmux
- [tmux Control Mode Wiki](https://github.com/tmux/tmux/wiki/Control-Mode)
- [tmux Formats Wiki](https://github.com/tmux/tmux/wiki/Formats)
- [iTerm2 tmux Integration](https://iterm2.com/documentation-tmux-integration.html)
- [libtmux — Python API for tmux](https://github.com/tmux-python/libtmux)
- [tmuxwatch — topology JSON dumper](https://github.com/steipete/tmuxwatch)

### Terminal Rendering
- [xterm.js](https://xtermjs.org/) — web terminal emulator
- [@fressh/react-native-xtermjs-webview](https://www.npmjs.com/package/@fressh/react-native-xtermjs-webview)
- [Blink Shell (hterm in WKWebView)](https://github.com/blinksh/blink)

### Markdown & Code
- [react-native-marked](https://www.npmjs.com/package/react-native-marked)
- [react-native-syntax-highlighter](https://www.npmjs.com/package/react-native-syntax-highlighter)
- [CodeMirror 6](https://codemirror.net/)
- [Shiki — VS Code TextMate syntax highlighter](https://shiki.style/)

### Networking
- [Tailscale vs WireGuard](https://tailscale.com/compare/wireguard)
- [Headscale — self-hosted Tailscale](https://github.com/juanfont/headscale)
- [Rathole — Rust NAT traversal](https://github.com/rathole-org/rathole)
- [awesome-tunneling](https://github.com/anderspitman/awesome-tunneling)

### Claude Code
- [Claude Code CLI Reference](https://code.claude.com/docs/en/cli-reference)
- [Claude Code Headless Mode](https://code.claude.com/docs/en/headless)
- [Claude Code Internals: Terminal UI](https://kotrotsos.medium.com/claude-code-internals-part-11-terminal-ui-542fe17db016)
- [strip-ansi (npm)](https://www.npmjs.com/package/strip-ansi)
- [ansi_up — ANSI to HTML](https://github.com/drudru/ansi_up)
