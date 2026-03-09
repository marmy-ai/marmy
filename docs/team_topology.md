# Team Topology

## Concept

Sessions come in two roles:

- **Manager** — can observe and instruct child sessions. Receives high-level goals from the user, decomposes them into tasks, and delegates to ICs.
- **Individual Contributor (IC)** — receives instructions (from a manager or the user directly), executes them, and reports status. Has no visibility into sibling sessions.

The **user** sits above the entire tree. They can interact with any session directly, but the power of the model is that they hand a goal to a manager and walk away.

```
         User
          |
       Manager A
       /       \
    IC-1      IC-2
```

Or flat (no manager):

```
    User
   / | \
 IC  IC  IC
```

Both topologies coexist — some sessions are manager-managed, others are user-managed standalone sessions (the current behavior).

---

## What changes from today

| Concern | Today | With teams |
|---|---|---|
| Session relationships | Flat list, no hierarchy | Parent-child graph |
| Inter-session communication | None | Manager reads IC output, sends instructions |
| Session metadata | name, id, attached | + role, parent_id, status |
| Mobile UI | Flat session list | Tree view / grouped by manager |
| Agent state | Topology only | Topology + team graph |

---

## Data model additions

### On the agent (Rust)

```rust
#[derive(Clone, Serialize, Deserialize)]
pub enum SessionRole {
    Manager,
    IC,
    Standalone, // legacy / user-managed, no team
}

#[derive(Clone, Serialize, Deserialize)]
pub struct TeamSession {
    pub tmux_session_id: String,   // links to TmuxSession.id
    pub role: SessionRole,
    pub parent_id: Option<String>, // manager's tmux_session_id (None for managers & standalone)
    pub children: Vec<String>,     // IC tmux_session_ids (empty for ICs)
}
```

This lives alongside (not inside) the existing `TmuxTopology`. The topology stays a flat tmux mirror; the team graph is an overlay the agent maintains separately.

### Persistence

Store in `~/.config/marmy/teams.json` (or a new `[teams]` section in config.toml). Needs to survive agent restarts. The tmux sessions themselves persist (tmux is durable), so we just need to persist the role/parent mappings.

---

## Instruction flow

The core question: how does a manager tell an IC what to do?

### Option A: Send-keys (simplest)

Manager's instructions are literally typed into the IC's pane via `tmux send-keys`. This is identical to how the mobile app sends input today.

```
Manager decides "run the tests" →
  Agent calls send_text_enter(ic_pane_id, "cargo test") →
  IC's tmux pane runs the command
```

**Pros:** Zero new infrastructure. Works with any program running in the pane (shell, vim, claude-code).
**Cons:** Fragile — the IC pane needs to be in a state that accepts that input. No queuing. Mixes instruction text with regular terminal I/O.

### Option B: Instruction channel via files (recommended starting point)

Each IC gets a well-known instruction file:

```
/tmp/marmy/<session_name>/instructions.md
```

- The manager (or user) writes to this file via a new API endpoint.
- The IC's process (e.g. a claude-code session) is configured to watch this file or read it on a trigger.
- The IC writes status/output to a sibling file (`status.md` or `output.md`).

**Pros:** Decoupled — IC doesn't need to be in a particular terminal state. Natural queuing (append instructions). Easy to inspect/debug. Works well with AI agents that can read files.
**Cons:** Requires the IC process to know about the file convention. Adds filesystem coupling.

### Option C: Agent-mediated message queue

The agent maintains an in-memory message queue per session:

```rust
pub struct SessionMailbox {
    pub instructions: VecDeque<Instruction>,
    pub status_updates: Vec<StatusUpdate>,
}
```

Exposed via new API endpoints. The IC process polls or subscribes via WebSocket.

**Pros:** Clean abstraction. No filesystem dependency. Can add priorities, ordering, acknowledgments.
**Cons:** Most complex. IC process needs to speak the marmy protocol. Doesn't survive agent restarts without persistence.

### Recommendation

**Start with Option B (file-based)**, with the agent managing the files. Reasons:

1. If the IC is running claude-code or another AI agent, file-based instructions are the most natural interface — these tools already read files.
2. The agent already has a file API (`/api/files/*`), so the mobile app can read/write instruction files through existing infrastructure.
3. It's inspectable — you can `cat` the instruction file to see what an IC was told to do.
4. Graduating to Option C later is straightforward once the interaction patterns stabilize.

---

## Manager capabilities

A manager session needs to:

1. **Spawn ICs** — create a new session with `role: IC` and `parent_id: self`
2. **Read IC output** — `capture-pane` / pane history (already supported via `/api/panes/:id/content`)
3. **Send instructions** — write to IC's instruction file
4. **Read IC status** — read IC's status file
5. **Kill ICs** — delete child sessions when done

All of these map onto existing primitives or trivial extensions:

| Capability | Implementation |
|---|---|
| Spawn IC | `POST /api/sessions` + new `role` and `parent_id` fields |
| Read IC output | `GET /api/panes/:id/history` (exists) |
| Send instruction | `PUT /api/sessions/:id/instruction` (new) |
| Read IC status | `GET /api/sessions/:id/status` (new) |
| Kill IC | `DELETE /api/sessions/:name` (exists) |

---

## How a manager actually runs

Two modes to consider:

### Mode 1: Manager is a claude-code session

The manager is itself an AI agent (claude-code) running in a tmux pane. It:
- Reads a goal from its own instruction file (set by the user)
- Decomposes the goal into sub-tasks
- Uses marmy's API (curl / a small CLI tool) to spawn ICs and send them instructions
- Polls IC status and pane output to track progress
- Reports back to the user

This is powerful but requires the manager's claude-code to know how to call marmy APIs. Could be solved with an MCP server or a simple shell script wrapper.

### Mode 2: Manager is agent-orchestrated (no tmux pane)

The manager isn't a tmux session at all — it's a logical entity inside the marmy agent. The agent itself does the decomposition and delegation. The mobile app provides the "manager UI."

**Recommendation:** Start with Mode 1. It's simpler (a manager is just another session), keeps the agent thin, and lets you iterate on the orchestration logic inside claude-code rather than in Rust.

---

## New API endpoints

```
POST   /api/teams                          Create a team (spawns a manager session)
GET    /api/teams                          List teams with their IC trees
DELETE /api/teams/:manager_id              Tear down manager + all ICs

POST   /api/teams/:manager_id/ics         Spawn an IC under this manager
DELETE /api/teams/:manager_id/ics/:ic_id   Remove an IC

PUT    /api/sessions/:id/instruction       Write instruction for a session
GET    /api/sessions/:id/instruction       Read current instruction
PUT    /api/sessions/:id/status            Write status update
GET    /api/sessions/:id/status            Read current status
```

The `/api/sessions` and `/api/panes` endpoints remain unchanged — they still work for flat session access. The team endpoints are a layer on top.

---

## Mobile UI changes

- **Sessions tab** groups sessions by team. Standalone sessions shown at the top; each team is a collapsible section headed by the manager.
- **Manager view** shows a dashboard: list of ICs with their current status and last output snippet.
- **Instruction composer** — tap an IC to send it a new instruction (text input that hits `PUT /api/sessions/:id/instruction`).
- **User can always "drop down" into any IC's terminal** for direct interaction, same as today.

---

## Phased rollout

### Phase 1: Data model + flat teams
- Add `SessionRole` and parent/child tracking to agent state
- Persist team graph to disk
- New API endpoints for team CRUD
- Mobile UI shows grouped sessions
- Instructions are manual (user types them via mobile)

### Phase 2: Manager autonomy
- Manager session can call marmy APIs to spawn/instruct ICs
- Provide an MCP server or CLI wrapper for claude-code to interact with marmy
- Manager reads IC output via pane capture, decides next steps

### Phase 3: Status reporting + feedback loops
- ICs write structured status updates
- Manager reacts to IC completion/failure
- Mobile shows real-time progress across the team
- User gets notifications when a team completes or hits a blocker

---

## Open questions

1. **IC process type** — Are ICs always claude-code sessions, or could they be plain shells, scripts, etc.? (Affects how instructions are delivered.)
2. **Concurrency limits** — How many ICs can a manager spawn? Resource constraints on the host machine?
3. **Error handling** — What happens when an IC fails? Does the manager retry, reassign, or escalate to the user?
4. **Cross-team visibility** — Can one manager's IC see another team's files/output? Probably not by default.
5. **User override** — If the user sends an instruction directly to a managed IC, does the manager know? Should it?
