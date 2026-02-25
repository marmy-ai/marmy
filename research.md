# Competitive Landscape & Existing Solutions

## The Short Version

One project — OpenClaw — covers this space as part of a much larger platform. Beyond that, the landscape is terminal apps, monitoring dashboards, and AI chat clients, none of which are purpose-built for the specific job of **supervising a coding agent from your phone**.

Marmy's bet is that this job deserves a dedicated, simple tool — not a module inside a platform.

---

## 1. Remote Terminal Apps (SSH Clients)

These are the closest existing category. They give you a terminal on your phone.

### Termius (iOS, Android)
- Full SSH/SFTP client, polished UI, cross-platform sync
- Good: Beautiful design, connection management, snippets, port forwarding
- Bad: It's a generic SSH client. You're staring at a raw terminal on a 6-inch screen. No concept of "sessions" or "agents." You *could* SSH into your laptop and attach to tmux, but the UX is painful — tiny text, no input shortcuts, full terminal emulation overhead
- Relevance: Proves there's demand for remote terminal access on mobile. Also proves that raw terminal on phone is a bad experience — you need an opinionated layer on top

### Blink Shell (iOS)
- Premium SSH/Mosh client, built for power users
- Good: Mosh support (persistent connections over flaky mobile networks), native terminal rendering, keyboard shortcuts
- Bad: iOS only. Designed for iPad with keyboard more than phone. Still a raw terminal experience
- Relevance: Mosh's approach to connection resilience is worth noting — Marmy's WebSocket + polling fallback solves a similar problem at the application layer

### Prompt by Panic (iOS)
- SSH client from the makers of Nova/Transmit
- Good: Clean, well-designed, reliable
- Bad: Minimal features compared to Termius. No Android. Raw terminal
- Relevance: Shows that "less is more" works for mobile terminal apps. Users don't want every feature — they want the right features

### a-Shell / iSH (iOS)
- Local terminal environments on iOS (not remote)
- Relevance: Not really comparable. These run local shells, not remote connections

**Takeaway from terminal apps:** They all give you *access* to a terminal but none of them give you a *purpose-built experience* for a specific workflow. Marmy's advantage is being opinionated — it knows you're supervising Claude Code, so it can strip away everything that doesn't serve that use case.

---

## 2. GitHub Mobile (iOS, Android)

The most relevant mainstream comparison. GitHub Mobile is to git repos what Marmy is to coding agents.

- Good: Excellent at the "check on things" use case — PR status, CI checks, review comments, merge. Notifications are first-class. The UX acknowledges that you're on mobile and limits what you can do accordingly (review code but don't write it)
- Bad: Code viewing on phone is painful (horizontal scroll hell). Actions/CI monitoring is shallow — you see pass/fail but debugging failures requires a laptop
- Relevance: **The best model for Marmy's UX philosophy.** GitHub Mobile doesn't try to be github.com on a phone. It's a companion app for monitoring + quick actions. Marmy should follow the same pattern: monitor terminal output + send quick inputs, nothing more

**Patterns to steal:**
- Pull-to-refresh everywhere
- Status indicators (green check, red X, yellow dot) visible at the list level
- Push into detail only when needed
- Quick actions (merge, approve) as simple buttons, not buried in menus

---

## 3. Server Monitoring Apps

These solve "check on background processes from your phone" — the same core problem.

### Datadog Mobile / Grafana Mobile
- Good: Dashboard-first design, alerting, quick glance at system health
- Bad: Information-dense, not action-oriented. You see problems but can't fix them from the app
- Relevance: Marmy has an advantage here — you can actually *act* (send instructions to the agent) not just observe

### ServerCat (iOS)
- Server monitoring with a consumer-friendly UI
- Good: Beautiful, simple, shows exactly what you need (CPU, memory, disk, network) at a glance
- Bad: Read-only. No way to take action
- Relevance: Great design inspiration for the project list. ServerCat makes server status glanceable — Marmy should make session status equally glanceable

### UptimeRobot / Better Uptime
- Uptime monitoring with mobile apps
- Good: Notifications when things go down, simple status pages
- Relevance: The notification model is interesting — Marmy could eventually push notifications when Claude asks a question or finishes a task. Not in v1, but the pattern fits

**Takeaway from monitoring apps:** The best ones are glanceable. You open them, see green/red, and close them. Marmy's project list should work the same way.

---

## 4. OpenClaw + ClawControl — The Direct Competitor

This is the one that actually overlaps with Marmy's territory.

### What it is
OpenClaw (formerly Clawdbot/Moltbot) is an open-source personal AI assistant platform by Peter Steinberger. It went viral in late January 2026. It runs locally, connects to messaging channels (WhatsApp, Telegram, Slack, Discord, Signal, iMessage), and can manage Claude Code sessions, run tests, capture Sentry errors, and open PRs autonomously.

ClawControl is its dedicated client app — React + Capacitor, runs on macOS, Windows, Android (iOS coming). It lets you stream multiple agents concurrently, spawn subagents, browse a skill marketplace, view agent reasoning, schedule cron jobs, and edit server configs.

### What it does well
- **Breadth**: Manages multiple agent types, not just Claude Code
- **Channels**: Meet users where they are — reply to your agent from WhatsApp or Slack without a dedicated app
- **Multi-agent**: Concurrent streaming, subagent spawning, isolated workspaces
- **Open source, growing community**: Viral adoption, active development

### What it does poorly (for Marmy's use case)
- **Complexity**: Gateway WebSocket control plane, RPC agent runtime, device nodes, bridge pairing, skill marketplace — it's a platform you adopt, not a tool you point at something
- **Setup burden**: You need to run the OpenClaw gateway, configure channels, set up agent routing. Marmy's setup is: enter IP, port, token, done
- **Opinionated about runtime**: OpenClaw wants to *be* your agent orchestrator. Marmy wraps what you already have (Claude Code + tmux) without replacing anything
- **Mobile client maturity**: ClawControl Android is out, iOS is "coming soon." The mobile UX specifics are thin — it's a Capacitor wrapper around a React app, not a mobile-first design

### What this means for Marmy

| | OpenClaw/ClawControl | Marmy |
|---|---|---|
| Philosophy | Platform you adopt | Tool you point at existing setup |
| Scope | Full AI assistant (coding, browsing, messaging, automation) | Claude Code session management only |
| Setup | Install gateway + configure channels + agent routing | Enter host, port, token |
| Mobile | Capacitor web wrapper (Android out, iOS coming) | Native-feel Expo app (both platforms) |
| Agent model | Multi-agent orchestration with skills/subagents | One agent per project, direct tmux |
| Learning curve | High — many concepts | Near zero — three screens |

**The positioning is clear:** OpenClaw is the platform play. Marmy is the sharp tool play. If you already have Claude Code running in tmux and just want a phone remote, Marmy gets you there in 2 minutes. If you want a unified AI assistant platform that manages your whole digital life, OpenClaw is the direction.

These can coexist. They serve different users at different stages. But Marmy should be honest that OpenClaw exists and articulate *why* less is more for the core use case.

---

## 5. Other AI Coding Tools — Mobile Story

### Claude Code
- CLI-only, no mobile client, no web UI, no remote access built-in
- The only way to use it remotely today is SSH + tmux (painful), OpenClaw (heavy), or Marmy (lightweight)
- Anthropic hasn't announced plans for a mobile Claude Code experience

### GitHub Copilot
- Lives inside VS Code / JetBrains / CLI. No standalone mobile app
- GitHub Mobile shows Copilot PR summaries but that's not the same as managing an agent

### Cursor / Windsurf
- Desktop IDE forks. No mobile story at all

### Aider
- CLI tool like Claude Code. No mobile client
- Same situation — you'd need SSH + tmux to access remotely

### ChatGPT / Claude.ai (web/app)
- Chat interfaces to models, not agent managers
- Can't point them at a local codebase, run commands, or manage sessions

**Takeaway:** Outside of OpenClaw, the AI coding tool space has no mobile solutions for agent management. The default assumption is still "you're at a desk."

---

## 6. Open Source / Community

### claude-code-related projects on GitHub
- Various wrapper scripts, VS Code extensions, and API clients
- A few "claude code web UI" projects exist but they're browser-based dashboards, not mobile-native apps
- OpenClaw is the main open-source project that touches this space (see section 4)

### Community discussions (Reddit r/ClaudeAI, HN)
- Recurring theme: people want to kick off Claude Code tasks and walk away
- Some use tmux + SSH as a workaround (exactly what Marmy wraps)
- Requests for a web UI or remote access are common
- OpenClaw gets attention for its breadth; complaints center on setup complexity

---

## 7. Summary Matrix

| Solution | Mobile? | Agent-aware? | Can act? | Real-time? | Simple setup? |
|---|---|---|---|---|---|
| Termius / Blink | Yes | No | Yes (raw) | Yes | Yes |
| GitHub Mobile | Yes | No | Limited | Yes | Yes |
| ServerCat | Yes | No | No | Yes | Yes |
| Datadog Mobile | Yes | No | No | Yes | No |
| Claude Code CLI | No | Yes | Yes | Yes | Yes |
| ChatGPT/Claude app | Yes | No | No | Yes | Yes |
| OpenClaw/ClawControl | Yes | Yes | Yes | Yes | No |
| **Marmy** | **Yes** | **Yes** | **Yes** | **Yes** | **Yes** |

OpenClaw checks the capability boxes but trades simplicity for breadth. Marmy's differentiator is doing less, faster, with less setup.

---

## 8. UX Patterns Worth Adopting

1. **GitHub Mobile's restraint** — Don't try to be the desktop experience. Be the companion.
2. **ServerCat's glanceability** — Status at the list level. Green = good, red = bad. No tapping required for the common case.
3. **Termius's connection management** — Save server configs, test connections, handle reconnection gracefully.
4. **Monitoring apps' notification model** — (Future) Push when the agent needs attention.
5. **iMessage-style input bar** — Familiar pattern for text input on mobile. Don't reinvent it.

## 9. UX Patterns to Avoid

1. **Raw terminal rendering on phone** — Tiny monospace text with full ANSI is unreadable. Strip it, simplify it.
2. **Horizontal scrolling for long lines** — Wrap text. Nobody wants to side-scroll on a phone.
3. **Overloaded toolbars** — Mobile screens are small. Every button must earn its place.
4. **Complex multi-step flows** — If killing a session takes more than 2 taps + a confirmation, it's too many.
5. **Settings as a maze** — Three fields (host, port, token) and a test button. That's it.
