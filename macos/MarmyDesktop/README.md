# Marmy Desktop

A native macOS workbench for running a small team of coding agents in tmux on
this Mac: lay out who reports to whom, start them, watch their terminals, and
talk to the one you have selected — by typing or by holding Space.

It is a standalone app. It does not need the Marmy menu-bar app, the Rust agent,
the relay, or the phone app.

## Build and run

```sh
cd macos/MarmyDesktop
./Scripts/build-app.sh            # release build
open "build/Marmy Desktop.app"
```

`build/` is git-ignored. The script bundles the app binary, the
`marmy-agent-launch` helper, SwiftTerm's resource bundle and licence, and an
icon, then ad-hoc signs the result.

macOS ties microphone and speech-recognition permission to the signing identity,
so an ad-hoc rebuild asks for them again. To keep the grants between builds:

```sh
MARMY_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./Scripts/build-app.sh
```

Development commands:

```sh
swift build                       # library + executables
swift test                        # unit tests, no tmux server needed
MARMY_RUN_TMUX_TESTS=1 swift test # plus integration tests on a private socket
```

Built with Xcode 26.4.1 on macOS 14+; Swift tools 5.9. The only third-party
dependency is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm), pinned to
the exact v1.20.0 commit `5d14406844143538cd8f8851d2d8a67c1fe443e5`.

## What you need installed

- **tmux** — every agent runs in a tmux session. `brew install tmux`. Without it
  the app opens, says so, and refuses to start anything.
- **The agent CLIs you plan to use** — `claude` and/or `codex` on your `PATH`.
  Marmy also looks in `~/.local/bin`, `/opt/homebrew/bin`, `/usr/local/bin`,
  `/usr/bin` and `/bin`, because an app launched from Finder inherits a thin
  `PATH`. Leave an agent's model box empty to use whatever that CLI is already
  configured to use; Marmy never invents a model id.

## The workflow

1. **New team** — pick a starter shape (a lead and one worker, a lead and two
   workers, or a single manager), a folder, and a CLI.
2. **Topology** — lay the team out (new agents are named Worker 1, Worker 2,
   Manager 1 … until you rename them): drag nodes, drag a node's bottom handle onto
   a manager to report to them, and use the inspector on the right for names,
   role, CLI, model, folder, manager, permitted contacts, role prompt, and extra
   instructions. Loops are refused with the reason.
3. **Launch team** — Marmy checks the whole team first: the graph, every rendered
   prompt, that each folder exists, that each CLI is installed, and that no
   session name is already taken. If anything fails, *nothing* is started. Each
   agent gets its own tmux session and its rendered prompt as its first message.
4. **Work** — the selected agent's terminal fills the window. Type in the
   composer and press ⌘↩, or hold Space to dictate. Move between agents with the
   keyboard; each keeps its own draft.

**Terminal nodes.** Set an agent's CLI to **Terminal** and it starts your login
shell in its folder instead of an agent: for scripts, build watches, or a harness
you drive by hand. It keeps its place in the graph — role, manager, contacts, the
lot — but Marmy sends it nothing: no starting prompt, no role instructions, no
automatic updates. Text typed into a shell is a command, and nobody is reading it
on the other end. Other agents are told it is a manual terminal and not to
message it. You can still type in it yourself, and still send it a line from
Marmy if you mean to.

**Scrolling back.** Scroll up in a terminal and Marmy opens that pane's real
tmux scrollback in a read-only view: selectable, colours intact, held still while
you read it. Escape or *Jump to live* returns. Nothing is sent to the agent to do
this — no keys, no tmux copy mode — and other terminals attached to the same
session see nothing change. (A tmux client draws on the alternate screen, which
has no scrollback of its own; left alone, a wheel gesture there is turned into
arrow keys and walks the agent's prompt history instead. Marmy takes the wheel
before that can happen.)

**Existing sessions.** Every tmux session on this Mac that is not part of a team
is listed under *Local sessions*. Opening one just attaches a terminal: nothing
is imported, renamed, restarted, or sent to it. It gets a draft and dictation
like any agent. To make one part of a team, select an agent and use *Attach an
existing session…* — still without sending it anything.

**Deleting.** *Delete team…* is in the team menu in the toolbar and in the
sidebar's context menu, and always asks first — the confirmation names the team
and lists the tmux sessions that will keep running. Removing a node or a team
removes Marmy's organisation only. Any session that was running keeps running and
reappears under *Local sessions*.

**Sidebar.** Each team opens and closes independently with its own chevron; they
can all be closed at once, and selecting an agent never reopens one.

## Keyboard

| Key | Does |
| --- | --- |
| ⌃⇥ / ⌃⇧⇥ | Next / previous agent at the same level (top-level agents cycle across every team) |
| ⌘↑ | Go to the manager |
| ⌘↓ | Go to the report you were in last, or the first one |
| Hold Space | Dictate to the selected agent (while the terminal has focus) |
| Tap Space | An ordinary space in the terminal |
| ⌘↩ | Send the draft |
| ⌘R | Start the selected agent |
| ⌘1 / ⌘2 | Work view / Topology view |
| ⌘N | New team |

Hierarchy keys work in the work view, including while the terminal has focus.
They stay out of the way while you are typing in a field: ⌘↑/⌘↓ keep their normal
text-editing meaning there.

**Two layers.** An agent with no manager is a top-level agent, and its peers are
the top-level agents of *every* team — so ⌃⇥ moves between the orchestrators you
are running, wrapping around. An agent that reports to someone cycles only among
that manager's reports, so you stay inside the team you are working in. Each team
remembers which report you were in, so coming back returns you there.

## Dictation

Hold Space (or press and hold the microphone button) to dictate into the draft of
the agent you are looking at. Marmy asks for **Microphone** and **Speech
Recognition** permission the first time you do that — never at launch. If either
is refused, the composer says which one and links to the right settings pane.

Recognition uses Apple's Speech framework. It stays on this Mac when the language
model for your locale supports it; when it does not, macOS sends audio to Apple's
servers, and the composer says *via Apple's servers* while that is happening.

A recording belongs to the agent it started on. Letting go, switching agent or
mode, opening a sheet, losing focus, or deleting that agent all end it, and a
result that arrives late can only ever land in the draft it was spoken for.
Dictation never sends anything by itself — you still press ⌘↩.

## Templates

*Templates* holds two things:

- **Role prompts** — the instructions an agent starts with. Edit them, duplicate
  them, or reset a shipped one. The editor lists every variable, reports syntax
  errors with a line number, and previews the result against a real agent.
- **Team shapes** — save the current team's structure and stamp out new teams
  from it later. A new team always gets fresh identities and unused session
  names; it never reuses the ones already running.

Editing a role prompt changes what *future* launches say. It is never injected
into an agent that is already running.

### Template variables

`{{topology.name}}`, `{{agent.name}}`, `{{agent.session}}`, `{{agent.kind}}`,
`{{agent.role}}`, `{{agent.cli}}`, `{{agent.model}}`, `{{agent.cwd}}`,
`{{agent.notes}}`, `{{manager.name}}`, `{{manager.session}}`, `{{manager.role}}`,
`{{reports}}`, `{{reports.list}}`, `{{contacts}}`, `{{contacts.list}}`,
`{{human.name}}`.

Sections: `{{#name}}…{{/name}}` renders when a value is present,
`{{^name}}…{{/name}}` when it is not. `{{agent.session}}` and the peer addresses
resolve to where an agent is *actually* reachable, so an attached session is
named by its real session, not the planned one.

## Where your data lives

- `~/Library/Application Support/MarmyDesktop/workspace.json` — teams, role
  prompts, team shapes, canvas positions. The previous version is kept beside it
  as `workspace.backup.json`. If the file cannot be read, Marmy says so and
  **does not** write over it.
- `~/Library/Application Support/MarmyDesktop/runtime.json` — which tmux session
  each agent is bound to.
- `~/Library/Application Support/MarmyDesktop/launch-specs/` — short-lived launch
  files, removed as each agent starts.

`MARMY_DATA_DIR` and `MARMY_TMUX_SOCKET` redirect all of that plus the tmux
server, which is how the tests and the smoke run stay away from your real data.

## Role rules are prompts, not enforcement

"Never commit", "only talk to your manager", "wait for an assignment" are
sentences in an agent's prompt. Marmy does not sandbox anything and cannot stop a
CLI from running any command it is capable of running. Treat the rules as
instructions to a colleague, not as a permission system.

## Checking a build without a screen recorder

```sh
swift run -c release MarmyDesktop --ui-smoke-test /tmp/marmy-ui
```

This runs the real views over an isolated workspace and its own private tmux
server, starts three fixture agents (a shell script that echoes its arguments and
then runs `cat` — no agent CLI, no model call), exercises selection, keyboard
navigation, drafts, dictation with scripted speech events, a real message
delivery, and reconnecting, then writes PNGs and `smoke-report.txt` and exits
non-zero if anything failed. It never touches your tmux server, your saved
workspace, the microphone, or screen-recording and accessibility permissions.

The sidebar appears blank in the full-window PNGs: macOS draws it in a vibrant
layer that `cacheDisplay` does not capture. `sidebar-content.png` renders the same
view on its own and shows it correctly.
