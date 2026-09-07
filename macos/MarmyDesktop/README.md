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
   a manager to report to them, and use the inspector on the right for the name,
   role, CLI, model, folder, manager, permitted contacts, role prompt, and extra
   instructions. Loops are refused with the reason.
3. **Launch team** — Marmy checks the whole team first: the graph, every rendered
   prompt, that each folder exists, that each CLI is installed, and that no
   session name is already taken. If anything fails, *nothing* is started. Each
   agent gets its own tmux session and its rendered prompt as its first message.
4. **Work** — the selected agent's terminal fills the window. You type in the
   terminal itself: there is no second box. Hold Space to dictate, and when you
   let go the words are put into that agent's own prompt for you to read, change,
   and send. Move between agents with the keyboard.

**Terminal nodes.** Set an agent's CLI to **Terminal** and it starts your login
shell in its folder instead of an agent: for scripts, build watches, or a harness
you drive by hand. It keeps its place in the graph — role, manager, contacts, the
lot — but Marmy sends it nothing: no starting prompt, no role instructions, no
automatic updates. Text typed into a shell is a command, and nobody is reading it
on the other end. Other agents are told it is a manual terminal and not to
message it. You can still type in it yourself, and still send it a line from
Marmy if you mean to.

**Images.** Paste a screenshot (⌘V) or drag one in, and Marmy saves it under
`pasted-images/` — readable only by you — and types its quoted path at the
prompt, without Enter. Dragging a file that already exists uses it where it is.
Files an app has only promised (a screenshot dragged straight out of Preview) are
received first, then typed. Nothing is ever deleted from that folder: an agent may
still be about to read it.

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
is imported, renamed, restarted, or sent to it. You can dictate into it like any
agent. To make one part of a team, select an agent and use *Attach an
existing session…* — still without sending it anything.

**Deleting.** *Delete team…* is in the team menu in the toolbar and in the
sidebar's context menu, and always asks first — the confirmation names the team
and lists the tmux sessions that will keep running. Removing a node or a team
removes Marmy's organisation only. Any session that was running keeps running and
reappears under *Local sessions*.

**Sidebar.** Clicking anywhere along a team's row — chevron, name, or the space
beside them — selects it and opens or closes it, the way a file explorer behaves.
Each team opens and closes independently, they can all be closed at once, and
selecting an agent never reopens one.

**Naming.** An agent has one name. It is the label you see, and the tmux session
name a future start asks for is derived from it: lower-cased, reduced to letters,
digits, hyphen and underscore, and moved out of the way of every name another
agent plans to use or the server already has (`verify`, then `verify-2`). The
inspector shows the real connection under the name — *Connected to tmux: …* for
a session that is running, *tmux name: …* for one that is not, and both when a
running session's name differs from what the next start would ask for. Renaming
never renames a tmux session or moves a binding: a running agent keeps the
session it is in, and other agents are still told its real address.

## Keyboard

| Key | Does |
| --- | --- |
| ⌃⇥ / ⌃⇧⇥ | Next / previous agent at the same level (top-level agents cycle across every team) |
| ⌘↑ | Go to the manager |
| ⌘↓ | Go to the report you were in last, or the first one |
| Hold Space | Dictate to the selected agent (while the terminal has focus) |
| Tap Space | An ordinary space in the terminal |
| ⌘V | Paste — text goes to the terminal; an image is saved and its path typed |
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

Hold Space (or press and hold the microphone button) to dictate to the agent you
are looking at. What you say appears under the terminal as it is heard; when you
let go it is **put into that agent's own prompt and left there** — Marmy never
presses Return for you. You read it, change it if you like, and send it from the
terminal. Marmy asks for microphone permission the first time you
hold, never at launch, and says which permission is missing if one is refused.

Marmy will not paste on its own if it cannot be sure the text is inert. tmux
gives no way to ask whether the program in a pane treats a pasted line break as
text or as Return, so anything with more than one line, or with control
characters in it, is **kept and offered back** — retry, copy, or discard — rather
than risking running it. Your own ⌘V in the terminal is untouched.

Words are never lost. If you move to another agent mid-sentence, if the terminal
reconnects, or if a paste cannot be confirmed, the transcript stays with the
agent it was spoken to, with a reason and buttons to try again, copy it, or throw
it away. When a paste's outcome is unknown, Marmy says so and asks you to look
before it will try again.

Recognition uses Apple's Speech framework. On macOS 26 Marmy uses the long-form
engine (`SpeechAnalyzer`), which is built for dictation that runs for minutes: it
commits stretches of speech as you talk and only revises its guess at the tail,
so the opening sentence of a five-minute prompt is still there at the end. It
runs on this Mac, from a language model kept locally; the first time you dictate,
Marmy says it is getting that ready rather than failing quietly.

Older systems use the short-utterance recogniser (`SFSpeechRecognizer`), which
stops on its own after about a minute. Marmy does **not** start another one and
carry on: a new recogniser would miss whatever was said across the changeover,
and there is no way to say how much. It stops, keeps every word already heard,
and tells you the dictation was interrupted so you can carry on where it left
off. Nothing is ever silently truncated. That recogniser may also send audio to
Apple's servers when on-device recognition is not available for your language —
the long-form engine on macOS 26 does not.

A recording belongs to the agent it started on. Letting go, switching agent or
mode, opening a sheet, losing focus, or deleting that agent all end it, and a
result that arrives late can only ever reach the agent it was spoken to.
Dictation never sends anything by itself: letting go puts the words in that
agent's own prompt, and you send them from the terminal with Return.

## Templates

*Templates* holds two things:

- **Role prompts** — the instructions an agent starts with. Edit them, duplicate
  them, or reset a shipped one. The editor says which prompt you are editing and
  which agents use it, lists every variable, reports syntax errors with a line
  number, and previews the result against a real agent.
- **Team shapes** — save the current team's structure and stamp out new teams
  from it later. A new team always gets fresh identities and unused session
  names; it never reuses the ones already running.

A role prompt is reusable, so the inspector offers both ways of changing one.
**Edit role prompt** opens the shared prompt itself: every agent using it is
affected, and the inspector says how many that is. **Customize for this agent**
copies it, assigns the copy to that agent alone, and opens the copy — its real
role text, not a paragraph appended to a shared one — leaving everyone else on
the original. Either way the change applies at the next start: it is never
injected into an agent that is already running.

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

## Team updates, and what each agent has been told

Editing a team changes what its agents believe about it. Marmy tells them, once
things settle: each agent gets **the team as it stands** — its manager (or you,
by name, for an agent at the top), its reports, who it may talk to, who may talk
to it, each with the tmux session it is really in, the pane it is really in, and
whether it is running yet. The whole picture rather than a list of edits, so an
update that has to wait can simply be replaced by a newer one without anything
being lost. Nothing is sent when nothing an agent would be told has changed:
renaming an agent letter by letter is one message, and an edit undone before it
settles is none. The message says explicitly that it updates team information
only — role instructions, and any rules about committing or pushing, are
untouched.

Marmy submits one of these by itself **only** when it can positively establish
that the agent is sitting at an empty prompt: the program in the pane is the one
Marmy started, nothing around the prompt says it is working or asking, the cursor
is at the CLI's own input line, and the whole input area is empty. Codex draws a
faint placeholder in an empty prompt, so the input is read with its colours on —
faint is a placeholder, anything else is something you typed. A screen Marmy does
not recognise is never taken as permission: the update waits, visibly, with
**Send now**, **Copy** and **Throw away**.

**Messages** in the work view shows what an agent has actually been told —
starting prompt included, in full, exactly as it was handed over, with where it
went and what became of it. "Delivered" means tmux took it; it never claims the
agent read it. Something Marmy could not confirm says so and is never sent again
on its own. A session Marmy attached rather than started says plainly that what
it was told before is not known.

## Where your data lives

- `~/Library/Application Support/MarmyDesktop/workspace.json` — teams, role
  prompts, team shapes, canvas positions. The previous version is kept beside it
  as `workspace.backup.json`. If the file cannot be read, Marmy says so and
  **does not** write over it.
- `~/Library/Application Support/MarmyDesktop/runtime.json` — which tmux session
  each agent is bound to.
- `~/Library/Application Support/MarmyDesktop/messages.json` — every message
  Marmy has sent an agent, with what became of it. Readable only by you. Nothing
  is ever trimmed from it: what an agent was told is the point of the file.
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
navigation, dictation with scripted speech events, a real message
delivery, and reconnecting, then writes PNGs and `smoke-report.txt` and exits
non-zero if anything failed. It never touches your tmux server, your saved
workspace, the microphone, or screen-recording and accessibility permissions.

The sidebar appears blank in the full-window PNGs: macOS draws it in a vibrant
layer that `cacheDisplay` does not capture. `sidebar-content.png` renders the same
view on its own and shows it correctly.
