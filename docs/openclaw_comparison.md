# Marmy vs OpenClaw: Full Competitive Assessment

> Generated: March 2026

## Executive Summary

OpenClaw is a 250K+ star open-source autonomous AI agent platform that connects to 25+ messaging channels and runs 24/7 on a server. Marmy is a mobile-first remote supervision tool for Claude Code sessions running on developer machines. They solve **fundamentally different problems** but share overlapping territory in AI agent management, voice interaction, and multi-agent orchestration.

**Bottom line:** OpenClaw is broader and more mature as a general-purpose AI agent platform. Marmy is sharper and more focused as a developer-oriented mobile supervisor for Claude Code workflows. They are less direct competitors and more complementary — but where they overlap, each has clear advantages.

---

## Category-by-Category Comparison

### 1. Core Purpose & Identity

| | Marmy | OpenClaw |
|---|---|---|
| **What it is** | Mobile remote control for Claude Code tmux sessions | General-purpose autonomous AI agent platform |
| **Primary interface** | Native iOS/Android app + macOS menu bar app | Chat via existing messaging apps (WhatsApp, Telegram, Slack, etc.) + web dashboard |
| **Core metaphor** | "Your dev team in your pocket" | "Your personal AI assistant, always on" |
| **Target user** | Developers running Claude Code on local machines | Power users, developers, small businesses wanting AI automation |

**Marmy is superior:** Laser-focused on the developer workflow. No confusion about what it does.
**OpenClaw is superior:** Broader appeal and utility. Useful for non-developers too.

---

### 2. Mobile Experience

| | Marmy | OpenClaw |
|---|---|---|
| **Native app** | Yes — React Native (iOS + Android), purpose-built | Companion apps on iOS + Android, but primarily a gateway connector |
| **UX philosophy** | "Glanceable over interactive" — optimized for 5-second check-ins | Chat-based — same as desktop, not mobile-optimized |
| **Terminal rendering** | Full ANSI 256-color parsing, custom renderer | No native terminal — text-based chat responses |
| **File browsing** | Built-in file tree, syntax highlighting, image/PDF preview | Via chat commands, no native file browser |
| **Session management** | Visual grid of worker cards, tap-to-chat, unread indicators | Text-based session listing via commands |
| **Offline resilience** | Stores machine configs locally, reconnects automatically | Requires constant connection to gateway |

**Marmy is clearly superior.** The mobile experience is Marmy's core product. OpenClaw's mobile apps are afterthoughts — thin wrappers around the same chat interface. Marmy has purpose-built screens for terminals, files, workers, and machines with native UX patterns (haptics, gestures, modals). OpenClaw's mobile story is essentially "just text your bot on WhatsApp."

---

### 3. Voice Assistant

| | Marmy | OpenClaw |
|---|---|---|
| **Voice model** | Google Gemini 2.5 Flash (bidirectional WebSocket) | ElevenLabs TTS + Whisper STT (or DeepClaw for phone calls) |
| **Voice role** | Relay between manager and Claude Code — reads session context, suggests instructions | General-purpose voice interaction with the agent |
| **Context awareness** | Injects last 100 lines of pane output every 7 seconds | Relies on conversation history |
| **Approval flow** | Manager must approve before instruction is sent to session | Direct execution (no approval gate) |
| **Push-to-talk** | Yes, native PTT mode | Wake word activation, continuous voice mode |
| **Echo cancellation** | Built-in AEC via speech processing filters | Platform-dependent |
| **Phone calls** | No | Yes, via DeepClaw + Deepgram Voice Agent API |
| **Wake word** | No | Yes (macOS/iOS) |

**Marmy is superior in:** Context-aware voice supervision — the voice assistant actually knows what's happening in your sessions and can relay instructions with approval. The "manager reviewing agent work" use case is uniquely served.

**OpenClaw is superior in:** Breadth of voice capabilities — wake words, phone calls, continuous listening, multiple TTS providers. More mature voice ecosystem with community tools (VoxClaw, Jupiter Voice).

---

### 4. Multi-Agent / Worker Management

| | Marmy | OpenClaw |
|---|---|---|
| **Agent model** | Tmux sessions running Claude Code instances | Isolated agent workspaces with separate SOUL.md/AGENTS.md |
| **Session creation** | One-tap from mobile: choose mode (Claude/terminal), directory, permissions | Configuration files or CLI commands |
| **Sessions Manager** | Dedicated Claude Code agent that monitors and coordinates other sessions | Multi-agent routing with orchestrator pattern |
| **Coordination** | Sessions Manager queries live output + conversation history of all agents | Hierarchical orchestration, sub-agent spawning |
| **Visibility** | Visual grid with unread indicators, tap any session to see live output | Text-based status via chat commands |
| **Scale** | Designed for 2-8 concurrent sessions on a dev machine | Designed for multi-gateway, multi-team deployment |

**Marmy is superior in:** Visual, mobile-native agent supervision. You can glance at your phone and see which agents are active, which have new output, and tap into any one. Creating sessions is a one-tap flow with a picker UI.

**OpenClaw is superior in:** Scale and sophistication. Multi-agent routing across teams, hierarchical orchestration, gateway-aware coordination, and OpenClaw Mission Control for enterprise dashboards. Marmy is single-machine; OpenClaw spans infrastructure.

---

### 5. AI/LLM Integration

| | Marmy | OpenClaw |
|---|---|---|
| **Primary AI** | Claude Code (Anthropic) — the agent running in sessions | Model-agnostic: Claude, GPT-4o, DeepSeek, Ollama local models, 15+ providers |
| **Model switching** | N/A — delegates to Claude Code | Dynamic per-task model routing (cheap model for easy tasks, premium for complex) |
| **Self-improving** | No — supervises Claude Code which has its own learning | Yes — can write new skills, create automation, maintain memory |
| **Tool use** | Through Claude Code's native tool system | 100+ preconfigured AgentSkills + can create new ones |
| **Browser automation** | Through Claude Code's MCP/Playwright | Native Playwright-powered browser control |
| **Local models** | No (relies on Anthropic API via Claude Code) | Yes, via Ollama (Llama, Mistral, Qwen, etc.) |

**OpenClaw is clearly superior.** It's a full AI agent platform with model routing, self-improving skills, and provider flexibility. Marmy intentionally delegates all AI work to Claude Code — it's a supervisor, not an agent itself.

---

### 6. Automation & Scheduling

| | Marmy | OpenClaw |
|---|---|---|
| **Cron jobs** | No built-in scheduler | Full cron system (one-time, interval, standard cron expressions) |
| **Proactive tasks** | No — reactive supervision only | Background tasks, reminders, daily summaries, inbox clearing |
| **Webhooks** | Push notification hooks for session events | HTTP endpoints for external systems |
| **Persistence** | Session state via tmux | Jobs persist across restarts, JSONL audit trails |

**OpenClaw is clearly superior.** It's designed for 24/7 autonomous operation. Marmy is a supervision tool — it watches work, it doesn't automate it independently.

---

### 7. Integration Ecosystem

| | Marmy | OpenClaw |
|---|---|---|
| **Messaging** | Push notifications (APNs) | 25+ channels: WhatsApp, Telegram, Slack, Discord, Signal, iMessage, IRC, Teams, etc. |
| **External APIs** | Via Claude Code's MCP servers | 50+ native service integrations + SKILL.md for any REST API |
| **Smart home** | No | Yes (IoT device control) |
| **Developer tools** | Git status (planned), tmux, Claude Code JSONL parsing | GitHub, GitLab, CI/CD, database access |
| **Extensibility** | Limited — agent API endpoints | Plugins (TypeScript), Skills (SKILL.md), Webhooks |

**OpenClaw is clearly superior.** The integration breadth is massive. Marmy is deliberately narrow — it integrates deeply with tmux and Claude Code, and that's it.

---

### 8. Desktop Experience

| | Marmy | OpenClaw |
|---|---|---|
| **macOS app** | Native SwiftUI menu bar app (MacMarmy) | Native companion app (macOS 15+), also Claw Desktop |
| **Purpose** | Auto-manages the Rust daemon, shows connection info | Gateway management, action approval, artifact review |
| **Windows** | Agent runs on any OS with tmux | Full support via WSL2 |
| **Linux** | Full agent support | Full native support |
| **Web dashboard** | No | Yes — chat, sessions, config, logs, skills pages |

**Roughly equal**, with different strengths. MacMarmy is simpler and more focused (start/stop agent, copy pairing info). OpenClaw's desktop tools are more feature-rich but also more complex.

---

### 9. Security

| | Marmy | OpenClaw |
|---|---|---|
| **Architecture** | Runs on your dev machine, connects over LAN/Tailscale | Runs as a 24/7 server, often internet-exposed |
| **Auth** | Bearer token, auto-generated, stored in SecureStore | Token-based, but often misconfigured |
| **Attack surface** | Small — single user, local network | Large — CVE-2026-25253 (RCE), 512 vulns in Jan 2026 audit, 42K exposed instances |
| **Malicious extensions** | None (no extension marketplace) | 824+ malicious skills found on ClawHub |
| **Prompt injection** | Minimal risk (terminal output, not web content) | Significant risk (processes emails, webpages, documents) |
| **Data locality** | All data stays on your machine | All data stays local (but exposed instances leak it) |
| **Approval flow** | Voice instructions require explicit approval | Optional approval controls, often disabled |

**Marmy is superior.** Drastically smaller attack surface. No marketplace for malicious extensions. No internet exposure by default (Tailscale is end-to-end encrypted). OpenClaw's security track record is a serious concern — CrowdStrike, Microsoft, and Cisco have all published advisories. China banned it from government machines.

---

### 10. Setup & Onboarding

| | Marmy | OpenClaw |
|---|---|---|
| **Server setup** | `cargo build && marmy-agent serve` — one binary | `npm install -g openclaw` then configure Gateway, channels, model providers |
| **Mobile setup** | Install app, enter hostname:port + token | Install companion app or just message on WhatsApp |
| **Config files** | One TOML file (`~/.marmy/config.toml`) | SOUL.md + AGENTS.md + USER.md + channel configs + model provider configs |
| **Prerequisites** | tmux, Rust toolchain, Claude Code | Node.js, model API keys, channel setup (varies by platform) |
| **Time to first use** | ~5 minutes | 15-60 minutes depending on channels and models |

**Marmy is superior** for getting started quickly. Single binary, one config file, pair and go. OpenClaw's flexibility comes at the cost of configuration complexity — choosing models, setting up channels, configuring memory, etc.

---

### 11. Community & Ecosystem

| | Marmy | OpenClaw |
|---|---|---|
| **GitHub stars** | Early stage / private | 250,000+ (one of the most starred repos ever) |
| **Contributors** | Solo developer | Massive open-source community, 47K+ forks |
| **Backing** | Independent | OpenAI (creator joined OpenAI), open-source foundation |
| **Extensions** | None | 10,700+ skills on ClawHub (though 824+ were malicious) |
| **Documentation** | Internal docs, step-by-step guides | Comprehensive docs site, community tutorials, YouTube content |
| **Enterprise adoption** | No | Yes — Mission Control, team orchestration |

**OpenClaw is overwhelmingly superior** in community and ecosystem size. This is the biggest gap in the comparison. OpenClaw has enterprise backing, massive community contribution, and an established extension ecosystem (despite security concerns).

---

### 12. Cost

| | Marmy | OpenClaw |
|---|---|---|
| **Software cost** | Free (MIT license) | Free (MIT license) |
| **Running cost** | Claude Code API usage (via Anthropic) + optional Gemini voice | Server hosting ($6-13/mo VPS) + model API calls ($6-200+/mo) |
| **Typical monthly** | Whatever you'd spend on Claude Code anyway + ~$0.10/min voice | $25-50/mo for small business, $200+/mo heavy use |
| **Local model option** | No | Yes (Ollama, $0 API cost) |

**Roughly equal** on software cost (both MIT). OpenClaw has more flexibility on model pricing. Marmy adds minimal overhead to existing Claude Code costs.

---

## Summary Scorecard

| Category | Marmy Advantage | OpenClaw Advantage | Winner |
|---|---|---|---|
| **Mobile UX** | Purpose-built, native, glanceable | Chat-based, platform-agnostic | **Marmy** |
| **Voice Supervision** | Context-aware, approval flow | Broader capabilities, wake words | **Marmy** (for dev use) |
| **Worker Visibility** | Visual grid, tap-to-chat, unread badges | Text-based listing | **Marmy** |
| **Terminal Rendering** | Full ANSI color, keyboard shortcuts | No native terminal | **Marmy** |
| **File Browsing** | Native tree, syntax highlighting | Chat-based | **Marmy** |
| **Security** | Tiny attack surface, Tailscale, no marketplace | Documented CVEs, malicious skills | **Marmy** |
| **Setup Speed** | 5 minutes, one config file | 15-60 minutes, multiple configs | **Marmy** |
| **AI Model Flexibility** | Claude Code only | 15+ models, local inference | **OpenClaw** |
| **Automation/Scheduling** | None | Full cron, proactive tasks | **OpenClaw** |
| **Integration Breadth** | tmux + Claude Code | 25+ channels, 50+ services | **OpenClaw** |
| **Multi-Agent Scale** | Single machine, 2-8 sessions | Multi-gateway, multi-team | **OpenClaw** |
| **Self-Improving AI** | No | Writes own skills, learns | **OpenClaw** |
| **Community/Ecosystem** | Early stage | 250K stars, massive ecosystem | **OpenClaw** |
| **Desktop App** | Clean menu bar agent manager | Richer dashboard + approval flows | **Tie** |
| **Cost Flexibility** | Tied to Anthropic pricing | Local models, dynamic routing | **OpenClaw** |

---

## Strategic Takeaways

### Where Marmy Wins
1. **The mobile supervision niche is uncontested.** OpenClaw has mobile apps, but they're chat wrappers. Marmy's purpose-built terminal rendering, worker grid, file browser, and voice supervision are in a different league for mobile UX.
2. **Security posture is dramatically better.** No exposed servers, no extension marketplace, no prompt injection surface from web content. For developers handling proprietary code, this matters enormously.
3. **Developer workflow integration is deeper.** Marmy understands tmux topology, Claude Code JSONL logs, pane state, and session types. OpenClaw treats everything as generic chat.
4. **Simplicity is a feature.** One binary, one config, one purpose. OpenClaw's flexibility creates real configuration overhead and decision fatigue.

### Where OpenClaw Wins
1. **Breadth and generality.** OpenClaw does everything — email, smart home, scheduling, web scraping, multi-platform messaging. Marmy does one thing well.
2. **Community and momentum.** 250K GitHub stars, OpenAI backing, massive contributor base. Marmy can't match this ecosystem gravity.
3. **Model flexibility.** Being model-agnostic with local inference support is a significant advantage for cost control and privacy.
4. **Autonomous operation.** OpenClaw runs 24/7 proactively. Marmy is reactive — it supervises work, it doesn't initiate it.

### Where Neither Clearly Wins
- **Voice:** Different strengths. Marmy's context-aware supervision voice is unique. OpenClaw's voice breadth (calls, wake words, continuous) is broader.
- **Desktop:** Both have native apps, both serve different purposes.
- **Cost:** Both are MIT-licensed. Real costs are API-driven and roughly comparable.

### The Real Question
These aren't really competitors — they're complementary. A developer could run OpenClaw for general automation (email, scheduling, smart home) and Marmy for supervising Claude Code dev work from their phone. The overlap is slim.

But if forced to choose one for **developer-focused AI agent supervision from mobile**, Marmy wins decisively. If choosing one for **general-purpose AI automation across your life**, OpenClaw wins decisively.
