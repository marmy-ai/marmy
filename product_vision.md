# Marmy — Product Vision

## The Problem

Claude Code is powerful, but it's chained to your laptop. You kick off a task — "refactor the auth module" — and then you wait. You sit there watching terminal output scroll, or you context-switch to something else and forget to check back. If you walk away to grab coffee, take a call, or move to the couch, you lose visibility. The agent keeps working, but you're flying blind.

The core tension: **AI coding agents do their best work asynchronously, but the tools we use to interact with them are synchronous and location-bound.**

You shouldn't need to be staring at a terminal to supervise an agent.

## What Marmy Is

Marmy is a **remote control for your coding agents**. It turns your phone into a supervisor's dashboard — you can see what Claude Code is doing, nudge it in the right direction, and manage multiple projects, all without being at your desk.

The mental model is closer to managing a team than writing code. You're the tech lead checking in on your reports. You dispatch work, review progress, course-correct when needed, and kill runaway tasks. The phone is the natural device for this — it's always with you, it's great for quick checks and short inputs, and it doesn't compete with your laptop's screen real estate.

## Who This Is For

A developer who:
- Uses Claude Code regularly across multiple projects
- Runs their dev server on a personal machine (reachable over Tailscale or local network)
- Wants to stay in the loop on agent progress without being physically at their desk
- Values the ability to fire off quick instructions on the go

This is not a replacement for sitting down and pair-programming with Claude. It's what you reach for when you're *not* sitting down.

## Key Scenarios

### 1. "Check on my agent" (60% of usage)

You started a refactor 20 minutes ago and went to a meeting. You pull out your phone, open Marmy, and immediately see the terminal output. Claude is asking a clarifying question about whether to preserve backward compatibility. You type "yes, keep the old interface as deprecated" and put your phone away. Total interaction: 15 seconds.

### 2. "Kick off a task" (20% of usage)

You're walking to lunch and remember you need to add input validation to the signup form. You open Marmy, tap the project, type "add email and password validation to the signup form, use zod schemas" and send. By the time you sit back down, it's done — or at least mostly done, waiting for your review.

### 3. "Manage my sessions" (15% of usage)

You have three projects going. One has an active Claude session that finished and is idle. Another is mid-task. You glance at the project list — green dots for active sessions, the project names and branches visible at a glance. You kill the idle session, check in on the active one, and move on.

### 4. "Something went wrong" (5% of usage)

Claude got stuck in a loop or went down a wrong path. You see it in the terminal output on your phone. You kill the session and fire off a new instruction with better guidance. Recovery takes 30 seconds instead of discovering the mess later.

## The Experience

### Project List — Your Command Center

The home screen is a clean list of your workspace projects. At a glance you know:
- **Which projects have active Claude sessions** (green dot + "Active" badge)
- **What branch each project is on** (so you don't send instructions to the wrong branch)
- **Which projects are ready but idle** (gray dot — no session running)
- **Which projects need git init** (yellow warning — Claude Code requires git)

Active sessions float to the top. This is intentional — the thing you most likely want to check on is the thing that's running right now.

Pull down to refresh. Tap to enter a session.

### Session View — The Terminal in Your Pocket

This is where you spend most of your time. It's deliberately simple:

**Top**: Project name, branch, and a connection indicator (green = live WebSocket, red = disconnected). You know immediately if you're seeing real-time data or stale output.

**Middle**: Terminal output in a dark, monospace view. This is a read-mostly surface — you're scanning for progress, errors, or questions from Claude. ANSI codes are stripped because color rendering on mobile adds complexity without proportional value. The text auto-scrolls to the bottom as new content arrives, because the latest output is almost always what you care about.

**Bottom**: A text input bar. Type a message, hit send. That's it. The input is deliberately minimal — no rich formatting, no file pickers, no slash commands. On mobile, you're sending short directives: "yes", "use postgres instead", "skip the tests for now", "looks good, commit it". This isn't where you write detailed specs.

The WebSocket connection means you see output as it happens — Claude typing, thinking, running commands. If the WebSocket drops (bad cell signal, Tailscale hiccup), it falls back to polling every 2 seconds. You might not even notice the switch.

### Settings — One-Time Setup

You configure the connection once: your machine's Tailscale IP, the port (3000 by default), and your auth token. Hit "Test Connection" to verify it works. The token goes in secure storage, the rest in regular storage. You shouldn't need to come back here unless you change machines.

## Design Principles

**1. Glanceable over interactive.** Most sessions are "open app, read terminal, close app." Optimize for the 5-second check-in, not the 5-minute editing session.

**2. Don't recreate the laptop experience.** The phone is a viewport into work happening elsewhere. Resist the urge to add code editing, file browsing, diff views, or anything that's better done at a desk. The phone's job is monitoring and short-form input.

**3. Connection quality is UX.** The difference between a real-time WebSocket and a 2-second poll is the difference between "live" and "laggy." Always show connection state. Never let the user wonder if what they're seeing is current.

**4. Sessions are cheap, mistakes are recoverable.** Killing a session and starting a new one should feel lightweight. Claude Code sessions are disposable by nature — the code changes persist in git, the session is just the conversation. Encourage the "kill and retry" pattern when things go sideways.

**5. Cross-platform is the point.** The iOS-native app works, but it only serves half the audience and requires a Mac to build. React Native with Expo lets us ship to both platforms from one codebase, buildable from any machine. The tradeoff in native feel is worth the reach.

## What This Is Not

- **Not an IDE.** You can't edit files, browse directories, or run arbitrary commands.
- **Not a chat app.** There's no conversation history, no message bubbles, no typing indicators. It's a terminal with an input box.
- **Not a Claude API client.** Marmy talks to *your laptop*, which runs Claude Code. It doesn't call the Anthropic API directly.
- **Not a collaboration tool.** One user, one laptop, one phone. There's no sharing, no team features.
- **Not voice-first (yet).** Voice input/output is deferred. The iOS app has TTS/STT experiments, but the RN app starts text-only. Voice is a natural fit for mobile agent interaction and may come later.

## Success Looks Like

You forget your phone has Marmy on it for most of the day. Then, at the right moment — waiting in line, sitting in a meeting, lying on the couch — you remember. You check on your agent in under 10 seconds. Maybe you send a quick reply. Then you put your phone down and move on with your life.

The best tool for managing an async agent is the device that's always in your pocket.
