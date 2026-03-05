# Push Notifications

Proposal for adding push notifications to Marmy — alerting users when agent sessions complete tasks or need input.

---

## Motivation

The core Marmy use case is "check on my agent" — but right now, you have to remember to check. You kick off a refactor, walk away, and either forget to look or compulsively open the app every 2 minutes. Notifications close this gap: the phone tells you when something needs your attention, so you can stop thinking about it until then.

---

## Scope: Two Events

This proposal covers exactly two notification triggers:

| Event | Description |
|-------|-------------|
| **Waiting for input** | Claude asked a question or needs approval and is blocked on you. You're the bottleneck. |
| **Task completed** | Claude finished work and returned to the prompt (or exited). You can review. |

---

## Detection

The Rust agent already monitors pane state via tmux control mode (`%output`, `%sessions-changed`, etc.) and can identify Claude processes by checking `current_command` on panes. Notification detection layers on top of this existing data.

### Task Completed

**Signal:** `current_command` on a pane transitions from `claude` (or a version string like `1.0.x`) to a shell (`zsh`, `bash`, `fish`).

This means the Claude process exited — the task is either done or it crashed. Either way, the user should know.

The agent already tracks pane state in its topology cache and receives tmux control mode notifications when processes change. Detection is a comparison between the previous and current `current_command` value on each topology refresh.

```rust
// Pseudocode for the detection check
fn check_pane_transition(prev: &TmuxPane, curr: &TmuxPane) -> Option<NotificationEvent> {
    let was_claude = is_claude_process(&prev.current_command);
    let is_shell = is_shell_process(&curr.current_command);

    if was_claude && is_shell {
        return Some(NotificationEvent::TaskComplete {
            pane_id: curr.id.clone(),
            session_name: curr.session_name.clone(),
        });
    }
    None
}

fn is_claude_process(cmd: &str) -> bool {
    cmd.contains("claude") || cmd.chars().next().map_or(false, |c| c.is_ascii_digit())
}

fn is_shell_process(cmd: &str) -> bool {
    matches!(cmd, "zsh" | "bash" | "fish" | "sh")
}
```

### Waiting for Input

**Signal:** The pane content ends with a Claude Code prompt pattern while `current_command` is still `claude`.

Claude Code has recognizable prompt states:
- The `> ` input prompt — task complete, awaiting next instruction
- Yes/no confirmation prompts (`Do you want to proceed?`, `Allow ...?`)
- Tool approval prompts

Detection approach: on each pane content poll (already happening at 500ms for active subscribers), check the last few lines against known prompt patterns. To avoid duplicate notifications, track whether we've already notified for the current prompt state.

```rust
fn check_waiting_for_input(pane: &TmuxPane, content: &str) -> Option<NotificationEvent> {
    if !is_claude_process(&pane.current_command) {
        return None;
    }

    let last_lines: Vec<&str> = content.lines().rev().take(5).collect();
    let tail = last_lines.join("\n");

    // Claude's input prompt (ready for next task)
    if tail.contains("> ") && tail.ends_with("> ") {
        return Some(NotificationEvent::WaitingForInput {
            pane_id: pane.id.clone(),
            prompt_type: PromptType::Ready,
        });
    }

    // Permission / confirmation prompts
    if tail.contains("Do you want to") || tail.contains("Allow ") || tail.contains("(y/n)") {
        return Some(NotificationEvent::WaitingForInput {
            pane_id: pane.id.clone(),
            prompt_type: PromptType::Confirmation,
        });
    }

    None
}
```

### Deduplication

To avoid spamming the same notification:
- Track `last_notified_state: HashMap<String, (NotificationEvent, Instant)>` per pane
- Only fire a notification if the event type changed or a cooldown (default: 2 minutes) has elapsed
- Reset the tracked state when the user sends input to that pane (they've seen it)

---

## Delivery: Expo Push Notifications

Expo Push Notifications is a free service that wraps APNs (iOS) and FCM (Android). It works in development and production — any Expo/EAS-built app deployed to the App Store can receive pushes through it.

### How it works

1. **Mobile app** registers for push notifications on launch, gets an Expo push token
2. **Mobile app** sends the token to the agent: `POST /api/notifications/register`
3. **Agent** stores the token (persisted to `~/.marmy/push_tokens.json`)
4. When a notification event fires, the **agent** POSTs to Expo's push API:

```
POST https://exp.host/--/api/v2/push/send
Content-Type: application/json

{
  "to": "ExponentPushToken[xxxxxx]",
  "title": "agent-frontend",
  "body": "Claude is waiting for input: Keep backward compat?",
  "data": { "pane_id": "%3", "session": "agent-frontend" },
  "sound": "default",
  "priority": "high"
}
```

No server infrastructure needed. The agent makes a single HTTPS POST. No APNs certificates to manage manually — Expo handles that through the EAS build pipeline.

### Fallback: WebSocket In-App Notifications

If the app is in the foreground, deliver the notification over the existing WebSocket instead of (or in addition to) a push:

```json
{ "type": "notification", "event": "waiting_for_input", "pane_id": "%3", "message": "Keep backward compat?" }
```

The mobile app shows this as a banner/toast. This also serves as the fallback if the user hasn't granted push permission.

---

## New Agent Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/api/notifications/register` | Register an Expo push token |
| DELETE | `/api/notifications/register` | Unregister a push token |
| POST | `/api/notifications/test` | Send a test notification to verify the pipeline |

### Register Request

```json
{ "token": "ExponentPushToken[xxxxxx]" }
```

### Token Storage

Simple JSON file at `~/.marmy/push_tokens.json`:

```json
{
  "tokens": ["ExponentPushToken[xxxxxx]"],
  "settings": {
    "waiting_for_input": true,
    "task_complete": true,
    "cooldown_seconds": 120
  }
}
```

---

## Mobile App Changes

### Setup (one-time)

```typescript
// mobile/src/services/notifications.ts
import * as Notifications from 'expo-notifications';
import { marmyApi } from './api';

export async function registerForPushNotifications() {
  const { status } = await Notifications.requestPermissionsAsync();
  if (status !== 'granted') return;

  const token = (await Notifications.getExpoPushTokenAsync()).data;
  await marmyApi.registerPushToken(token);
}
```

Call `registerForPushNotifications()` after connecting to a machine.

### Notification Tap Handling

When the user taps a notification:
1. App opens (or comes to foreground)
2. Read `pane_id` from notification data
3. Navigate to Sessions tab, select that pane
4. Scroll to latest content

```typescript
Notifications.addNotificationResponseReceivedListener((response) => {
  const { pane_id, session } = response.notification.request.content.data;
  // Navigate to the session/pane
  navigationRef.navigate('sessions', { paneId: pane_id });
});
```

### In-App Banner

For foreground notifications, show a dismissible banner at the top of any screen:

```
┌──────────────────────────────────────┐
│  agent-frontend waiting for input    │
│  "Keep backward compat?"     [Go]   │
└──────────────────────────────────────┘
```

Tap "Go" to jump to that session.

### Settings

Add a "Notifications" section to existing settings:
- Toggle: "Notify when waiting for input" (default: on)
- Toggle: "Notify when task completes" (default: on)
- "Send test notification" button

---

## Implementation Plan

### Agent (Rust)

1. Add `NotificationEvent` enum and `NotificationDetector` struct in a new `notifications` module
2. Add push token file storage at `~/.marmy/push_tokens.json`
3. Add `/api/notifications/register`, `/api/notifications/test` endpoints
4. Hook detection into the existing topology refresh loop:
   - Compare previous vs current `current_command` per pane → task complete
   - On pane content updates, check last lines for prompt patterns → waiting for input
5. Add deduplication tracker (HashMap of last notified state per pane)
6. Add Expo push HTTP client — one `reqwest::Client::post()` call, no SDK needed
7. Add WebSocket notification message type for in-app delivery

### Mobile (React Native)

1. Add `expo-notifications` to dependencies
2. Add `notifications.ts` service — register token, handle taps
3. Call registration after machine connection in `connectionStore`
4. Add notification response listener in app root for deep linking
5. Add in-app banner component
6. Add notification toggles to settings

---

## Cost

| Item | Cost |
|------|------|
| Expo Push Service | Free |
| `expo-notifications` package | Free |
| Agent HTTPS calls to Expo | Negligible |

No new infrastructure. No APNs certificate management. No push notification server to run.

---

## Risks

| Risk | Mitigation |
|------|------------|
| False "waiting for input" — prompt pattern matched mid-output | Only match when content is stable (no change for 1+ seconds) and `current_command` is still `claude` |
| Duplicate notifications | Deduplication map with cooldown; reset on user input to that pane |
| Expo push token expiry | Re-register on each app launch; handle `DeviceNotRegistered` errors from Expo API and remove stale tokens |
| Agent needs internet for push | Already has internet (Claude API requires it). Expo push is a single HTTPS POST. |
