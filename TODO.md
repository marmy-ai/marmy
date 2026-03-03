# Marmy — Feature TODO

Ordered by importance. Use `/prioritize` to evaluate where a new idea fits.

---

## P0 — Core Experience Gaps

- [ ] **BUG: Can't create sessions when none exist** — If there are no tmux sessions other than the internal `_marmy_ctrl` session, the mobile app has no way to create a new one. Users get stuck with no sessions to interact with.

- [x] **macOS menu bar app** — Replace the CLI daemon with a native menu bar app (like Tailscale). Shows agent status in the top-right corner, makes setup dead simple (launch app, it runs), and gives quick access to sessions without touching the terminal.

- [x] **Live keyboard mode** — Send keystrokes individually instead of buffering into a message. Enables arrowing through Claude Code's autocomplete options, navigating menus, and real-time key-by-key interaction. The agent already supports raw byte input — this is a mobile UI change.

## P1 — High-Value Enhancements

- [ ] **Seamless Tailscale integration** — Detect Tailscale automatically, use Tailscale IPs for pairing, and streamline the connection flow so users don't need to manually find IPs or configure networking. Include showing the Tailscale IP in `marmy-agent pair` output when Tailscale is detected.

- [ ] **Team topology** — Treat tmux sessions as team members. Define team structures and hierarchies (leads, sub-agents), assign roles, and get recommended org layouts based on project needs.

- [ ] **Ralph loops (agent cron)** — Set up scheduled autonomous runs for high-level agents. Define cron-like rules so trusted sessions can execute tasks on a cadence without manual triggering.

- [ ] **Voice comms** — Voice input to send messages to sessions (speech-to-text) and voice output to hear responses read back (text-to-speech). Enables hands-free interaction with agents.

## P2 — Quality of Life

- [ ] **Session folder scope from menu bar** — Add a setting in the macOS menu bar app to configure which folders sessions can start from. Let users define allowed root directories so new sessions are scoped to specific project folders instead of defaulting to a single path.

- [ ] **Session-aware file browsing** — Instead of a fixed `allowed_paths` list, derive file roots from sessions. Each tmux session's working directory becomes a browsable root, so file access automatically matches what you're working on without manual config.

- [ ] **QR code pairing** — Generate a QR code in the menu bar app or CLI (`marmy-agent pair --qr`) containing the address and token. Scan from the mobile app to add a machine instantly — no manual typing.

- [ ] **App polish** — General cleanup pass on the mobile app. Tighten UI consistency, fix rough edges, improve navigation flow, and handle error/empty states gracefully.

- [ ] **Backspace in live keyboard mode** — Backspace key doesn't work when in live keyboard (KB) mode. Need to send the correct escape sequence or control character so backspace behaves as expected during real-time key-by-key input.

- [ ] **Clearer MSG/KB mode toggle UX** — The current MSG/KB toggle button is cryptic for new users. Add better affordances — e.g. a brief tooltip on first use, more descriptive labels, or a small onboarding hint explaining the two input modes.

- [ ] **Image viewing in file browser** — Render images inline when browsing files in the mobile app, instead of showing raw binary or nothing.

- [ ] **Markdown rendering in file browser** — Render markdown files with proper formatting (headers, lists, code blocks, etc.) when viewing them in the mobile app.

- [ ] **Quick-launch shortcuts without permissions** — Add shortcuts/widgets to launch Claude sessions directly without requiring permission prompts each time. Could include iOS shortcuts, home screen widgets, or app intents.


## P3 — Polish and Expansion

- [ ] **Menu bar screensaver** — Show an animated screensaver from the macOS menu bar app. Visualize active sessions with movement — pulsing dots, flowing connections, terminal activity sparklines, or a little constellation of agents doing work. Something cute and ambient that makes the menu bar feel alive.
