# Marmy Project Evolution Notes — 2026-02-26

## The Elephant in the Room

Anthropic shipped **Claude Code Remote Control** on February 25, 2026 — literally yesterday.
It does exactly what marmy does: run Claude Code on your laptop, continue the conversation
from your phone. The feature uses outbound HTTPS polling (no inbound ports), auto-reconnects
on sleep/network drops, and streams through the Anthropic API over TLS.

Setup is one command: `claude remote-control`. Scan a QR code with the Claude mobile app and
you're in. Full access to your local filesystem, MCP servers, tools, and project config. The
terminal stays open, the session stays alive.

Currently gated to Claude Max ($100-200/mo), Pro ($20/mo) coming soon. No Team/Enterprise yet.

Simon Willison's initial review noted it's "a little bit janky right now" — permission issues,
API 500 errors, one session at a time — but these are launch-day bugs, not design limitations.

**Bottom line:** the core marmy use case — "remote tmux terminal on your phone" — is now a
first-party feature. Competing with Anthropic on their own CLI's built-in capability is not a
viable path.

### Sources

- https://code.claude.com/docs/en/remote-control
- https://simonwillison.net/2026/Feb/25/claude-code-remote-control/
- https://venturebeat.com/orchestration/anthropic-just-released-a-mobile-version-of-claude-code-called-remote
- https://www.helpnetsecurity.com/2026/02/25/anthropic-remote-control-claude-code-feature/

---

## What Marmy Still Has (and Remote Control Doesn't)

Remote Control is a *conversation window*. It shows you Claude's text responses and lets you
type prompts. What it does NOT provide:

1. **Rich code/markdown rendering** — Remote Control is a text stream. There's no syntax
   highlighting, no rendered markdown, no collapsible code blocks, no diffview. Claude's
   output is full of markdown (code fences, headers, lists, tables) that gets displayed as
   raw text in a terminal context.

2. **Multi-machine management** — Remote Control is one session on one machine. Marmy already
   has a machines tab for managing multiple development servers.

3. **Structural views of work** — Remote Control shows a linear conversation. It has no way
   to visualize task graphs, agent topologies, or parallel workstreams.

4. **File browsing with rendering** — Marmy already has a file browser. Adding syntax
   highlighting and markdown rendering to file viewing would make it a proper mobile code
   review tool.

---

## Proposed Pivot: Two Directions

### Direction 1: Rich Rendering Layer

The immediate, high-value pivot. Claude Code output is *full* of:
- Markdown (headers, bold, lists, tables)
- Code blocks with language tags (```typescript, ```rust, etc.)
- Diffs (unified diff format)
- File paths and line references
- Structured tool call results

A mobile client that actually *renders* this properly — syntax-highlighted code blocks, rendered
markdown, expandable diffs, tappable file paths — would be significantly more useful than raw
terminal text, whether that text comes from marmy's tmux bridge or from Remote Control itself.

**React Native rendering options:**
- `react-native-markdown-display` — CommonMark renderer using native components (not webview)
- `react-native-syntax-highlighter` — syntax highlighting for code blocks
- `react-native-remark` — markdown + syntax highlighting + dark mode
- Custom renderer combining marked.js parsing with native RN views

The rendering layer could potentially work *on top of* Remote Control's output too, making it
complementary rather than competitive.

### Direction 2: Agent Topology Orchestration

This is the bigger, more ambitious play. The multi-agent space is exploding in 2026:

**What exists now:**
- Claude Code has **Agent Teams** (experimental) — a lead agent delegates to teammates working
  in parallel, each in its own context window. Teammates can message each other and claim from
  a shared task board.
- Claude Code has **subagents** (Task tool) — focused workers that report back to a parent,
  but can't communicate with each other.
- Third-party tools: claude-flow (swarm orchestration), Oh My Claude Code, various open-source
  frameworks.

**What's missing — the orchestration UI:**
Nobody has a good *visual interface* for managing agent topologies on mobile. The current state
of multi-agent is:
- CLI-only: you watch terminal logs scroll by
- No visualization: you can't see which agents are running, what they're working on, how
  they relate to each other
- No intervention: you can't pause, redirect, or reprioritize agents from a phone

**What marmy could become:**
A mobile command center for multi-agent coding workflows. Picture:
- A topology view showing agents as nodes, task dependencies as edges
- Task boards showing what each agent is working on, what's blocked, what's done
- The ability to spin up new agents, assign tasks, and monitor progress
- Rich rendering of each agent's output (code, diffs, markdown)
- Cross-agent coordination views (who is touching which files, merge conflicts, etc.)

This aligns with where the industry is heading. Deloitte, Gartner, and the Anthropic agentic
coding trends report all point to orchestrated multi-agent systems as the next major shift.
The "bag of agents" approach (just throw more agents at it) fails due to coordination overhead
— what's needed is *structured topologies* with clear task graphs.

### Sources

- https://code.claude.com/docs/en/agent-teams
- https://addyosmani.com/blog/claude-code-agent-teams/
- https://www.codebridge.tech/articles/mastering-multi-agent-orchestration-coordination-is-the-new-scale-frontier
- https://towardsdatascience.com/why-your-multi-agent-system-is-failing-escaping-the-17x-error-trap-of-the-bag-of-agents/
- https://shipyard.build/blog/claude-code-multi-agent/

---

## Recommended Path Forward

**Phase 1 — Rich rendering (immediate)**
- Add markdown rendering to the terminal view (Claude output is markdown)
- Add syntax highlighting for code blocks
- Add diff rendering (unified diff → side-by-side or inline color-coded view)
- Make file paths tappable (jump to file browser with highlighted lines)
- This is valuable regardless of whether input comes from tmux, Remote Control, or an API

**Phase 2 — Agent topology views (next)**
- Build a task graph visualization (nodes = agents/tasks, edges = dependencies)
- Integrate with Claude Code's Task tool / agent teams API
- Show real-time status of parallel agents
- Allow task creation and agent spawning from mobile
- Provide cross-agent file conflict detection

**Phase 3 — Orchestration control plane (later)**
- Design and manage agent topologies: define which agents exist, what tools they have,
  how they communicate
- Template topologies for common patterns (research → plan → implement → test)
- Save and replay topologies across projects
- Cost/token monitoring per agent

---

## Architecture Implications

The rendering layer (Phase 1) requires:
- Swapping plain-text terminal view for a markdown/code rendering view
- Parsing Claude Code output format (tool calls, responses, streaming text)
- New components: MarkdownView, CodeBlock, DiffView, FileLink

The topology layer (Phase 2-3) requires:
- New data model: agents, tasks, dependencies, messages
- New API endpoints on marmy-agent (or integration with Claude Code's native APIs)
- Graph layout algorithm for mobile (dagre, d3-hierarchy, or custom)
- WebSocket for real-time agent status updates

The good news: the existing marmy architecture (Rust agent + React Native app + REST/WS) is
already well-suited for this. The agent just needs new endpoints, and the app needs new views.
