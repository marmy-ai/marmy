# Full-Duplex Voice Mode via Gemini Live API — Feasibility Assessment

Assessing the viability of adding a full-duplex voice mode to the Marmy mobile app, where a Gemini Live model acts as a conversational overlay on any tmux session — the user speaks, the model sees the terminal, talks back, and writes to the shell via tool calling.

**Use case:** User is running, driving, or otherwise hands-free. They open voice mode on a session, have a natural conversation about what's happening in the terminal, and the model executes commands on their behalf when they agree.

---

## Concept

```
User (voice) ←──── full duplex audio ────→ Gemini Live API
                                                │
                                          reads terminal context
                                          (injected periodically)
                                                │
                                          calls write_to_shell() tool
                                                │
                                                ▼
                                          Marmy Agent REST API
                                                │
                                          POST /api/panes/:id/input
                                                │
                                                ▼
                                            tmux pane
```

No STT/TTS pipeline. No intermediary LLM. One model does voice understanding, reasoning, voice synthesis, and tool execution in a single WebSocket connection.

---

## How Gemini Live API Works

### Connection

Persistent WebSocket to `wss://generativelanguage.googleapis.com/ws/...BidiGenerateContent`.

1. Client sends `setup` message: model ID, system instructions, tools, generation config
2. Server responds `setupComplete`
3. Client streams audio via `realtimeInput` (continuous PCM chunks)
4. Server streams audio responses back
5. Server can issue `toolCall` mid-conversation; client responds with `toolResponse`
6. Client can inject text context anytime via `clientContent`

### Audio Format

| Direction | Format | Sample Rate | Encoding |
|-----------|--------|-------------|----------|
| Input (user voice) | 16-bit PCM, mono | 16 kHz | Little-endian |
| Output (model voice) | 16-bit PCM, mono | 24 kHz | Little-endian |

### Models

| Model | Status | Notes |
|-------|--------|-------|
| `gemini-2.5-flash-native-audio-preview-12-2025` | Preview (GA on Vertex AI) | Recommended. Thinking enabled by default. |
| `gemini-2.5-flash-preview-native-audio-dialog` | Preview | Dialog-optimized variant |
| `gemini-2.0-flash` (Live variants) | Stable | Older, stable. Retiring June 2026. |

30 HD voices, 24 languages on the 2.5 models.

### Session Limits

| Config | Limit |
|--------|-------|
| Audio-only (no compression) | 15 minutes |
| Audio-only (with `contextWindowCompression`) | Unlimited |
| Connection lifetime | ~10 min (server sends `GoAway`, reconnect with `sessionResumption`) |
| Resumption token validity | 2 hours after disconnect |

Practical implication: for sessions longer than ~10 minutes, the client must handle `GoAway` messages and reconnect using session resumption tokens. This is well-documented and straightforward, but must be implemented.

---

## Critical Question: Does Tool Calling Work Mid-Audio?

**Yes, but with caveats.**

Gemini Live supports function calling during audio streams. The flow:

1. Model decides to call a tool → sends `toolCall` with function name, args, and ID
2. Client fires the tool (calls marmy REST API to send input to the pane)
3. Client immediately sends `toolResponse` with `{ "success": true }` — no waiting for terminal output
4. Model continues speaking (e.g., "Sent it. I'll let you know what happens.")
5. Terminal output shows up in the next periodic context injection — the model reacts then if relevant

### The caveat

Google's docs state: **"Audio inputs and audio outputs negatively impact the model's ability to use function calling."** The 2.5 Flash model has improved triggering rates over 2.0, but it is still less reliable than text-only function calling.

### Mitigation

- Keep tool definitions simple and few (one tool: `write_to_shell`)
- Use clear system instructions that emphasize when to call the tool
- Mark the tool as `NON_BLOCKING` with `WHEN_IDLE` scheduling — the model finishes speaking, then fires the tool
- **Fire-and-forget execution:** The tool call sends input to the terminal and immediately returns success. There's no "output" to wait for — the model will see what happened on the next context injection (5-10 seconds later). This keeps the audio stream flowing without awkward pauses.
- Test extensively; if reliability is too low, consider a hybrid where the model outputs a text intent and client-side logic triggers the tool

### Our tool definition

```json
{
  "name": "write_to_shell",
  "description": "Send text input to the active tmux terminal session. Appends a newline to submit the command. Only call this when the user has confirmed or clearly asked you to execute something.",
  "parameters": {
    "type": "object",
    "properties": {
      "text": {
        "type": "string",
        "description": "The text/command to type into the terminal"
      }
    },
    "required": ["text"]
  }
}
```

---

## Injecting Terminal Context

The model needs to see what's on screen to have an informed conversation. Gemini Live supports this via `clientContent` messages — text injected into the conversation context at any time.

### Strategy

1. **On session start:** Inject current pane content (last ~100 lines) as initial context
2. **Periodic refresh:** Every 5-10 seconds, or after a tool call, re-inject the latest pane content
3. **On tool call completion:** Immediately inject updated pane content so the model can see the result

### Implementation

```
// Pseudocode for context injection loop
every 5 seconds:
  pane_content = GET /api/panes/{id}/content
  if pane_content changed since last injection:
    send clientContent message with:
      role: "user"
      text: "--- TERMINAL UPDATE ---\n{pane_content}\n--- END TERMINAL ---"
```

### Caveat

Sending `clientContent` **interrupts current model generation**. This means if the model is mid-sentence and you inject context, it will stop and re-evaluate. Solutions:

- Only inject when the model is idle (not currently speaking)
- Use a flag to track model speaking state and queue context updates
- Or accept brief interruptions as natural (model picks up where it left off)

---

## Architecture: Where Does the WebSocket Live?

### Option A: Mobile → Gemini directly

```
Mobile App ──── WebSocket ────→ Gemini Live API
     │
     └── REST ────→ Marmy Agent (for pane content + tool execution)
```

- **Lowest latency** (no proxy hop). Google explicitly recommends this.
- Use **ephemeral tokens** (created via Gemini API, valid up to 20 hours) so the API key never reaches the client. The agent mints ephemeral tokens on demand.
- Mobile fetches pane content from marmy agent and injects it into the Gemini socket.
- On `toolCall`, mobile calls marmy agent REST API to execute, then sends `toolResponse` back to Gemini.

### Option B: Mobile → Agent → Gemini

```
Mobile App ──── WebSocket ────→ Marmy Agent ──── WebSocket ────→ Gemini Live API
```

- Agent proxies all audio.
- Higher latency (extra hop through agent, which may be over Tailscale).
- Agent handles context injection and tool execution server-side.
- Simpler mobile implementation.

### Recommendation: Option A (direct connection)

Latency is everything for voice. Adding a Tailscale hop through the agent for every audio frame would noticeably degrade the experience. The ephemeral token pattern keeps the API key safe. The mobile app already talks to the marmy agent for pane content and input — that path stays the same.

The only downside: the Gemini API key (or a Google Cloud project) needs to be configured. But the agent can mint ephemeral tokens via a new endpoint (`GET /api/voice/token`), so the user only configures the key once on the agent side.

---

## Cost Analysis

### Per-token pricing (Gemini 2.5 Flash Native Audio, Live API)

| Type | Cost per 1M tokens |
|------|---------------------|
| Text input | $0.50 |
| Audio input | $3.00 |
| Text output | $2.00 |
| Audio output | $12.00 |

### Estimated cost per minute of conversation

Rough token rates (from Google docs and community reports):

| Component | Tokens/min (est.) | Cost/min |
|-----------|-------------------|----------|
| Audio input (user speaking ~50% of the time) | ~750 | $0.002 |
| Audio output (model speaking ~50% of the time) | ~750 | $0.009 |
| Text context injection (terminal content, ~2K tokens every 10s) | ~12,000 | $0.006 |
| Text output (tool calls, reasoning) | ~500 | $0.001 |
| **Subtotal (naive)** | | **~$0.02/min** |

### The compounding problem

Gemini Live bills **all accumulated tokens in the context window per turn**, not just new tokens. Each turn re-processes everything before it. For a 5-minute conversation with ~20 exchanges:

- Early turns: cheap (small context)
- Later turns: increasingly expensive (growing context)
- Estimated multiplier: 2-3x the naive per-minute rate

**Realistic estimate: $0.04-0.08/min** for a typical voice session.

### Context window compression

Enabling `contextWindowCompression` (sliding window) caps the accumulation. This is essential for sessions longer than a few minutes. It should be enabled by default.

### Comparison

| Approach | Cost/min | Notes |
|----------|----------|-------|
| **Gemini Live (this proposal)** | ~$0.04-0.08 | Single model, full duplex, tool calling |
| Pipeline (Deepgram + ElevenLabs) | ~$0.02-0.03 | No reasoning, just relay. From voice_interface.md |
| OpenAI Realtime (gpt-realtime-mini) | ~$0.80 | More mature tool calling |
| OpenAI Realtime (gpt-realtime) | ~$5.00 | Best quality, very expensive |
| ElevenLabs Conversational AI | ~$0.08-0.10 | Pipeline with any LLM |

**Verdict:** Gemini Live is cost-competitive. Roughly 2-3x the dumb pipeline, but you get an actual reasoning agent that understands terminal context and can act — not just a speech relay. Dramatically cheaper than OpenAI Realtime.

---

## Latency Assessment

### Expected round-trip

| Segment | Latency |
|---------|---------|
| Mic capture + PCM encoding | ~20ms |
| WebSocket to Gemini (direct) | ~50-100ms |
| Model processing (speech-to-speech) | ~200-400ms |
| Audio playback start | ~20ms |
| **Total speak-to-hear** | **~300-550ms** |

This is within conversational range. Phone calls have ~200-300ms latency and feel natural. Sub-600ms is acceptable.

### Risk: Tailscale-routed tool calls

When the model calls `write_to_shell`, the mobile app must call the marmy agent (possibly over Tailscale), execute the command, and return the result. This adds:

- Tailscale relay: 50-200ms (depending on DERP vs direct)
- Agent processing: ~50ms
- Total tool call round-trip: ~100-300ms

During this time, audio output pauses. A 100-300ms pause is barely noticeable — it feels like the model is thinking.

### Risk: Context injection latency

Fetching pane content from the agent (over Tailscale) every 5-10 seconds adds background network calls. These don't block the audio stream — they run concurrently.

---

## Mobile Implementation

### New dependencies

```json
"expo-av": "^14.0.0"           // Microphone access, audio session management
"@google/genai": "^1.44.0"     // Gemini SDK with Live API support
```

No Opus codec needed — Gemini Live uses raw PCM, and `expo-av` can capture/play PCM natively.

### Key components

1. **VoiceModeButton** — toggle in the terminal toolbar (alongside MSG/KB)
2. **VoiceSession** — manages the Gemini Live WebSocket lifecycle
   - Opens connection with setup (system prompt, tool definitions)
   - Streams mic audio as `realtimeInput`
   - Plays received audio through speaker
   - Handles `toolCall` → calls marmy agent → sends `toolResponse`
   - Periodically fetches + injects pane content via `clientContent`
   - Handles `GoAway` + session resumption for long sessions
3. **VoiceOverlay** — minimal UI shown during voice mode
   - Waveform visualization (user speaking)
   - Speaking/listening state indicator
   - Tap to interrupt
   - End voice session button

### System prompt for voice sessions

```
You are a voice assistant for a terminal session. You can see what's on the terminal screen (provided as periodic context updates) and talk to the user about it.

You have one tool: write_to_shell. Use it ONLY when the user explicitly asks you to run a command or confirms an action. Never execute commands without clear user consent.

Keep responses concise — you're having a voice conversation, not writing an essay. Summarize terminal output rather than reading it verbatim. If the user asks "what's happening", describe the current state briefly.

When the terminal context updates, note any significant changes (command completed, error appeared, build finished) and proactively mention them.
```

---

## Agent-Side Changes

Minimal:

1. **New endpoint: `GET /api/voice/token`** — Calls Gemini API to create an ephemeral token, returns it to the mobile app. This keeps the API key on the agent.
2. **Config: `gemini_api_key`** — Added to agent config (config.toml or env var).

That's it. The agent doesn't proxy audio. The existing `/api/panes/:id/content` and `/api/panes/:id/input` endpoints handle context fetching and tool execution — no changes needed.

---

## Risks and Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Tool calling unreliable with audio | Medium | Keep tool definitions minimal (1 tool). Fire-and-forget (no waiting for output). Use clear system instructions. Test with 2.5 Flash. Fall back to text intent extraction if needed. |
| 15-min session limit | Low | Enable `contextWindowCompression` + `sessionResumption`. Reconnect transparently. |
| `clientContent` interrupts model speech | Medium | Only inject context when model is idle. Track speaking state. Queue updates. |
| Compounding token costs | Low | Enable context window compression. Typical voice sessions are short (2-5 min). |
| No echo cancellation | Medium | Gemini Live doesn't handle AEC. Use headphones or implement client-side AEC. On speakerphone, the model may hear its own output. |
| Gemini Live is still in preview | Medium | Core API is stable (GA on Vertex AI). Native audio models are preview. Have a fallback plan (OpenAI Realtime mini, or the pipeline approach from voice_interface.md). |
| React Native audio streaming | Medium | `expo-av` handles basic recording. May need a thin native module for continuous PCM streaming at 16kHz. The LiveKit React Native SDK could help here. |
| API key management | Low | Agent mints ephemeral tokens (up to 20hr validity). Key never reaches mobile. |

---

## Comparison to Pipeline Approach (voice_interface.md)

The existing `voice_interface.md` describes a cascaded pipeline: Deepgram STT → text relay to tmux → diff output → ElevenLabs TTS. That design treats voice as a dumb transport layer — speech in, text out, text in, speech out.

| Dimension | Pipeline (voice_interface.md) | Gemini Live (this proposal) |
|-----------|-------------------------------|------------------------------|
| **Intelligence** | None — just relays text | Full reasoning about terminal state |
| **Conversation** | Not conversational — speak command, hear output | Natural back-and-forth discussion |
| **Architecture** | Complex — 3 cloud services + agent proxy | Simple — 1 WebSocket to Gemini + existing REST |
| **Agent changes** | Heavy — new `/ws/voice` endpoint, Deepgram/ElevenLabs clients, Opus codec | Light — one `/api/voice/token` endpoint |
| **Mobile changes** | Heavy — Opus codec, audio proxy, voice WebSocket | Moderate — PCM capture/playback, Gemini SDK |
| **Cost** | ~$0.02-0.03/min | ~$0.04-0.08/min |
| **Latency** | ~400-600ms (STT + network + TTS) | ~300-550ms (end-to-end model) |
| **Tool calling** | N/A — just types text | Native (with reliability caveats) |
| **Offline fallback** | WhisperKit + AVSpeechSynthesizer | None (cloud-only) |

### Verdict

The Gemini Live approach is **simpler to build, more capable, and comparably priced**. The pipeline is cheaper per-minute but delivers far less value — it's just a speech-to-text relay with no understanding.

The pipeline approach still has value as a fallback (offline mode, or if Gemini Live tool calling proves too unreliable), but for the primary experience, Gemini Live is the better path.

---

## Recommendation

**Do it.** The Gemini Live API is production-viable for this use case:

- Full duplex voice with tool calling — exactly what you described
- Direct client connection keeps latency low
- Cost is reasonable (~$0.04-0.08/min, comparable to a phone call)
- Agent-side changes are minimal (one new endpoint for token minting)
- Mobile-side is moderate (Gemini SDK + audio capture/playback + UI)
- The "running and can't type" scenario works naturally

### Suggested phases

1. **Prototype** — Get a basic voice session working: connect to Gemini Live, stream audio, inject pane content, handle one tool call. No polish, no edge cases. Validate that tool calling reliability is acceptable.
2. **Polish** — Session resumption, context injection timing, interruption handling, echo cancellation, UI states.
3. **Ship** — Add to terminal toolbar as VOICE mode. Token configuration in agent settings.
4. **Iterate** — Evaluate whether to add the pipeline approach from voice_interface.md as an offline/fallback option.

### Open questions

1. **Google Cloud vs AI Studio** — Gemini Live is GA on Vertex AI (Google Cloud) but preview on AI Studio. Which auth path? Vertex AI is more stable but requires a GCP project.
2. **Echo cancellation** — Speakerphone use requires AEC. Is headphone-only acceptable for v1?
3. **Context injection frequency** — How often to refresh terminal content? Too often = interruptions + cost. Too rare = stale context.
4. **Multiple panes** — Should the model see one pane or the full tmux topology? Start with one, expand later.
