# Terminal UX Improvements

Improvements to the terminal tab's output readability and keyboard input experience.

---

## 1. Output Readability

The terminal currently renders Claude Code output as a flat monospace text dump. No parsing of Claude Code's internal format — these are purely visual improvements on the existing raw text.

### ANSI Code Rendering
Claude Code already outputs ANSI escape codes for bold, dim, color, etc. We currently strip or ignore them. Respecting these gives us visual hierarchy for free:
- Bold text (headers, emphasis)
- Dim text (secondary info, tool status)
- Color (errors in red, etc.)

### Typography
- Increase line height slightly for better scanability
- Consider SF Mono or JetBrains Mono over Menlo — more readable at small sizes
- Evaluate whether a small font size bump helps on mobile

### Prompt Boundary Separation
Detect prompt boundaries (e.g., the `>` or `$` character at line start) and add visual breaks:
- Subtle background shading or a thin horizontal divider between input/output chunks
- Simple regex match, not a fragile parser

---

## 2. KB Mode — Shortcut Bar Redesign

### Fixed Grid Layout
Replace the horizontal scroll strip with a fixed 2-row grid. All keys visible at once, no scrolling:

```
[ Esc ] [ Tab ] [ Ctrl ] [  ^  ] [ DEL ]
[  <  ] [  v  ] [  >  ] [  CR ] [ MSG ]
```

- `Ctrl` acts as a modifier — tap Ctrl, then tap a character on the native keyboard = Ctrl+combo
- `DEL` = backspace (visible, tappable, no more relying on TextInput delta detection)
- `CR` = carriage return / Enter
- `MSG` = switch back to MSG mode

### Haptic Feedback
Add light haptic tap on each shortcut button press.

---

## 3. Mode Toggle Clarity

The current MSG/KB toggle is ambiguous — unclear whether the label refers to the active mode or the mode you'd switch to.

### Fix
- Show the **current mode** as a label, not the target
- Use distinct visual states so the active mode is obvious
- Options:
  - Segmented control with both `MSG | KB` visible, active one highlighted
  - Or label like "Mode: MSG" with a tap to toggle
- Segmented control is probably the cleanest — both options always visible, highlighted state = current mode
