# Marmy — Feature TODO

Ordered by importance. Use `/prioritize` to evaluate where a new idea fits.

---

## P0 — Core Experience Gaps

- [x] **macOS menu bar app** — Replace the CLI daemon with a native menu bar app (like Tailscale). Shows agent status in the top-right corner, makes setup dead simple (launch app, it runs), and gives quick access to sessions without touching the terminal.

- [x] **Live keyboard mode** — Send keystrokes individually instead of buffering into a message. Enables arrowing through Claude Code's autocomplete options, navigating menus, and real-time key-by-key interaction. The agent already supports raw byte input — this is a mobile UI change.

## P1 — High-Value Enhancements

- [ ] **Team topology** — Treat tmux sessions as team members. Define team structures and hierarchies (leads, sub-agents), assign roles, and get recommended org layouts based on project needs.

- [ ] **Ralph loops (agent cron)** — Set up scheduled autonomous runs for high-level agents. Define cron-like rules so trusted sessions can execute tasks on a cadence without manual triggering.

## P2 — Quality of Life

- [ ] **App polish** — General cleanup pass on the mobile app. Tighten UI consistency, fix rough edges, improve navigation flow, and handle error/empty states gracefully.

- [ ] **Clearer MSG/KB mode toggle UX** — The current MSG/KB toggle button is cryptic for new users. Add better affordances — e.g. a brief tooltip on first use, more descriptive labels, or a small onboarding hint explaining the two input modes.


## P3 — Polish and Expansion
