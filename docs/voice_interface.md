# Voice Interface Design

Research and architecture for adding voice comms to Marmy — speech-to-text input and text-to-speech output for hands-free agent interaction from the mobile app.

---

## Current Architecture Context

The mobile app (React Native/Expo) communicates with the Rust agent daemon over REST + WebSocket. Messages reach tmux sessions via `POST /api/panes/:id/input`, and pane output is polled via `GET /api/panes/:id/history`. All communication is text-based JSON today — no audio endpoints, no audio infrastructure in the React Native app.

The legacy native Swift iOS app has a working `VoiceService.swift` that uses Apple's `SFSpeechRecognizer` for STT and `AVSpeechSynthesizer` for TTS. This serves as a reference but is not wired to the current React Native app.

**Key insight:** Voice input just needs to produce text that feeds into the existing `sendInput(paneId, text + "\n")` path. Voice output needs to detect new pane content and speak it. The plumbing is already there — voice is a new input/output modality layered on top.

---

## Recommended Stack

| Component | Primary | Offline Fallback |
|-----------|---------|------------------|
| **STT** | Deepgram Nova-3 (cloud, WebSocket) | WhisperKit on-device |
| **TTS** | ElevenLabs Flash v2.5 (WebSocket streaming) | AVSpeechSynthesizer |
| **VAD** | Silero VAD | Apple PushToTalk framework |
| **Transport** | WebSocket (binary audio frames) | — |
| **Audio codec** | Opus 24kbps (iOS <-> agent) | PCM 16kHz/16-bit for API ingestion |
| **UX mode** | Push-to-talk (phase 1) | VAD auto-detect (phase 2) |

### Why this stack

- **Deepgram Nova-3:** Sub-300ms latency, native WebSocket streaming, $0.0043-0.0077/min. Best real-time STT price-to-performance. Your Go/Rust backend maintains a persistent WebSocket to Deepgram, forwarding audio chunks from the mobile app.
- **WhisperKit (offline fallback):** On-device Whisper via CoreML on Apple Neural Engine. 2.2% WER (best accuracy tested), ~450ms per-word latency. Free, fully offline. Swift Package at [argmaxinc/WhisperKit](https://github.com/argmaxinc/WhisperKit). Bundle `whisper-small` (~500MB) or `whisper-base` (~150MB) to keep app size reasonable.
- **ElevenLabs Flash v2.5:** 75ms time-to-first-audio, WebSocket bidirectional streaming, best voice naturalness. Purpose-built for LLM output streaming — pipe text in, get audio chunks back. ~$0.03-0.05/1K characters.
- **Silero VAD:** 87.7% true positive rate at 5% false positive rate. Free, open source. iOS library available: [RealTimeCutVADLibrary](https://github.com/helloooideeeeea/RealTimeCutVADLibrary) — bundles Silero VAD + WebRTC noise suppression.

### Cost estimate (cascaded pipeline)

| Component | Cost/Minute |
|-----------|-------------|
| Deepgram Nova-3 STT | ~$0.006 |
| LLM (if routing through one) | ~$0.005 |
| ElevenLabs Flash TTS | ~$0.015 |
| **Total** | **~$0.02-0.03/min** |

For comparison, OpenAI Realtime API (all-in-one speech-to-speech) costs ~$0.30/min — 10x more, but handles everything in one API call including VAD, interruption, and turn-taking.

---

## Architecture

### Data Flow

```
iOS App                         Rust Agent                     Cloud
─────────                       ──────────                     ─────

AVAudioEngine
  ├─ Silero VAD (on-device)
  │   └─ detects speech start/stop
  │
  ├─ Opus encode
  │   └─ 20ms frames, 24kbps
  │
  └─ WebSocket ──binary──►  /ws/voice endpoint
                               │
                               ├─ Opus decode → PCM 16kHz
                               │
                               ├──── WebSocket ────►  Deepgram Nova-3
                               │                         │
                               │◄─── transcript ─────────┘
                               │
                               ├─ sendInput(paneId, transcript)
                               │   └─ text goes to tmux session
                               │
                               ├─ poll pane output / diff new content
                               │
                               ├──── WebSocket ────►  ElevenLabs TTS
                               │                         │
                               │◄─── audio chunks ───────┘
                               │
                               ├─ Opus encode
                               │
                               └─ WebSocket ──binary──►  iOS App
                                                           │
                                                     Opus decode
                                                           │
                                                     AVAudioPlayerNode
                                                           │
                                                        Speaker
```

### Why route audio through the agent (not direct-to-cloud from iOS)

1. **Single auth boundary** — API keys for Deepgram/ElevenLabs stay on the server, never ship to the client
2. **Unified protocol** — the mobile app speaks one WebSocket dialect to the agent; the agent fans out to cloud services
3. **Output diffing** — the agent already has pane content; it can diff new output and pipe it to TTS without the iOS app needing to parse terminal output
4. **Offline pivot** — swapping to on-device STT/TTS only changes the iOS side, not the protocol

### New Agent Endpoints

```
GET /ws/voice?pane_id={id}    WebSocket upgrade for voice channel
```

**Client → Agent (binary frames):** Opus-encoded audio chunks (20ms frames)

**Agent → Client (text frames, JSON):**
```json
{ "type": "transcript",   "text": "deploy to staging", "final": true }
{ "type": "tts_audio",    "format": "opus" }   // followed by binary frame
{ "type": "state",        "listening": true, "speaking": false }
{ "type": "error",        "message": "STT connection lost" }
```

**Agent → Client (binary frames):** Opus-encoded TTS audio chunks

**Client → Agent (text frames, JSON):**
```json
{ "type": "config", "stt": "deepgram", "tts": "elevenlabs", "voice": "rachel" }
{ "type": "interrupt" }   // stop TTS playback, cancel pending speech
{ "type": "mode", "value": "push_to_talk" | "vad" | "off" }
```

---

## Speech-to-Text: Deep Dive

### Deepgram Nova-3 (Primary)

- WebSocket endpoint: `wss://api.deepgram.com/v1/listen`
- Send raw PCM or Opus audio; receive JSON transcripts
- Key params: `model=nova-3`, `language=en`, `smart_format=true`, `interim_results=true`, `utterance_end_ms=1000`
- `interim_results` gives partial transcriptions as the user speaks (show in UI as preview)
- `utterance_end_ms` controls how long silence triggers a "final" transcript
- The agent maintains a persistent WebSocket to Deepgram per active voice session; audio from the iOS app is decoded and forwarded

### WhisperKit (Offline Fallback)

- Swift Package: `github.com/argmaxinc/WhisperKit`
- Runs Whisper models on Apple Neural Engine via CoreML
- First run compiles the model (~4 min on first use, cached after)
- Per-word latency: ~450ms — acceptable for push-to-talk
- iOS 17+ required (already our minimum target)
- Detect offline state → switch to WhisperKit automatically
- Models: `whisper-small` (good accuracy/size tradeoff) or `whisper-base` (smaller, slightly less accurate)

### Apple Speech Framework (Lightest option)

- Already proven in our `VoiceService.swift`
- Free, zero dependencies, works offline (with reduced accuracy)
- Rate-limited: 1,000 requests/hour/device, 1 minute max per request
- Accuracy lags behind Deepgram and WhisperKit
- Good enough as a tertiary fallback or for quick prototyping

---

## Text-to-Speech: Deep Dive

### ElevenLabs Flash v2.5 (Primary)

- WebSocket endpoint for bidirectional streaming
- Send text chunks in, receive audio chunks out — designed for LLM output streaming
- 75ms time-to-first-audio
- Superior naturalness: 82% pronunciation accuracy (vs 77% OpenAI), 64.57% prosody (vs 45.83% OpenAI)
- Voice cloning available for custom agent voices
- The agent streams new pane content (diffed) into the ElevenLabs WebSocket and forwards audio back to iOS

### Deepgram Aura-2 (Budget Alternative)

- Sub-200ms TTFB, GPU-accelerated
- $0.030/1K chars — cheaper than ElevenLabs
- Single-vendor with Deepgram STT (simpler billing, one SDK)
- Quality is good but not ElevenLabs-tier

### AVSpeechSynthesizer (Offline Fallback)

- Zero latency, fully on-device
- Noticeably robotic compared to cloud TTS
- iOS 17+ has "enhanced" and "premium" quality tiers
- Already implemented in our legacy `VoiceService.swift`
- Strip ANSI codes from terminal output before speaking (reference implementation exists)

---

## Voice Activity Detection

### Silero VAD (Recommended)

- Neural network model, runs via ONNX Runtime or CoreML on iOS
- 87.7% TPR at 5% FPR — misses ~1 in 8 speech frames
- iOS library: [RealTimeCutVADLibrary](https://github.com/helloooideeeeea/RealTimeCutVADLibrary)
  - Bundles Silero VAD + WebRTC APM noise suppression
  - Real-time processing, Swift-native
- Audio: 16kHz sample rate input
- Speech detection params (Silero v5): speech starts when 50% of frames exceed 70% VAD probability within a 0.32s window

### Apple PushToTalk Framework (iOS 16+)

- System-level PTT button accessible from Lock Screen
- Manages audio session activation for background transmit/receive
- Displays system UI without launching the app
- Could provide the PTT UX while Silero handles VAD for auto-mode

### When to use which

- **Push-to-talk mode:** No VAD needed — user explicitly presses button to start/stop
- **Hands-free mode:** Silero VAD detects speech onset → starts streaming to STT → detects silence → finalizes transcript → sends to session
- **Background mode:** Apple PushToTalk framework for system-level integration

---

## UX Design

### Input Modes (Voice Adds a Third)

The app currently has MSG mode (type a message) and KB mode (live keystrokes). Voice becomes the third:

| Mode | Input | Send Trigger | Best For |
|------|-------|-------------|----------|
| MSG | Typed text | Tap send | Composing prompts |
| KB | Individual keys | Each keystroke | TUI navigation |
| VOICE | Spoken words | Release PTT / silence | Hands-free commands |

### Push-to-Talk UI

```
┌─────────────────────────────────┐
│  Session: agent-frontend        │
│  ┌─────────────────────────────┐│
│  │                             ││
│  │  [terminal output area]     ││
│  │                             ││
│  │                             ││
│  └─────────────────────────────┘│
│                                 │
│  "deploy to staging"            │  ← live transcript preview
│                                 │
│  ┌───┐  ╔═══════════╗  ┌───┐  │
│  │MSG│  ║  MIC (hold)║  │ KB│  │
│  └───┘  ╚═══════════╝  └───┘  │
└─────────────────────────────────┘
```

**Button states:**
1. **Idle** — mic icon, neutral color
2. **Recording** — pulsing red ring, waveform animation, haptic on press
3. **Processing** — spinner, "Transcribing..." label
4. **Agent speaking** — speaker icon with sound waves, tap to interrupt

**Haptic feedback:**
- Light impact on press-down (transmit start)
- Medium impact on release (transmit end)
- Notification haptic when agent response arrives and TTS begins

**Audio indicators:**
- Subtle "blip" tone on transmit start
- Different tone on agent response arrival

### Voice Response Flow

1. User holds mic button → audio streams to agent → Deepgram transcribes
2. Live transcript appears above the mic button as partial results arrive
3. User releases button → final transcript sent to session as text input
4. Agent polls pane output, diffs new content
5. New content is stripped of ANSI codes, sent to ElevenLabs TTS
6. Audio streams back to iOS, plays through speaker
7. Transcript of agent response also shown in the terminal view

### Interruption

User can tap the mic button while agent is speaking to:
- Immediately stop TTS playback
- Cancel any queued audio
- Start recording new voice input

This sends an `{ "type": "interrupt" }` message over the voice WebSocket.

---

## Implementation Plan

### Phase 1: Push-to-Talk with Cloud Pipeline

**Goal:** Hold a button, speak a command, hear the response read back.

**Agent-side (Rust):**
1. Add `/ws/voice` WebSocket endpoint
2. Maintain a Deepgram WebSocket connection per voice session
3. Forward incoming Opus audio → decode to PCM → send to Deepgram
4. Receive transcripts → call `tmux.send_text_enter()` on the target pane
5. Diff pane output on each poll cycle → pipe new text to ElevenLabs WebSocket
6. Forward ElevenLabs audio → encode to Opus → send back to client
7. Handle `interrupt` messages (cancel pending TTS, close Deepgram utterance)

**Mobile-side (React Native):**
1. Add `expo-av` for audio recording/playback
2. Build a native module (or use `react-native-audio-api`) for `AVAudioEngine` access with Opus encoding
3. PTT button component with press/release gesture handling
4. WebSocket connection to `/ws/voice?pane_id={id}` when voice mode is active
5. Live transcript display from partial STT results
6. Audio playback queue for TTS response chunks
7. UI states: idle, recording, processing, speaking

**Config:**
- Deepgram API key in agent config (`config.toml`)
- ElevenLabs API key in agent config
- Voice selection (ElevenLabs voice ID) configurable from mobile settings
- STT language preference

### Phase 2: VAD + Hands-Free Mode

**Goal:** No button needed — start speaking and the system detects it.

1. Integrate Silero VAD on-device (via native module wrapping `RealTimeCutVADLibrary` or ONNX Runtime)
2. VAD runs continuously on mic input when hands-free mode is active
3. Speech detected → start streaming audio to agent
4. Silence detected → stop streaming, trigger finalization
5. Smart turn detection: combine Silero VAD with a brief semantic check (is the sentence complete?) to avoid premature cutoffs
6. Add mode toggle in UI: PTT / Hands-Free / Off

### Phase 3: Offline Voice

**Goal:** Voice works without internet.

1. Bundle WhisperKit with `whisper-small` model in the iOS app
2. Detect network state; switch STT to WhisperKit when offline
3. Switch TTS to AVSpeechSynthesizer when offline
4. Audio stays on-device — no WebSocket streaming needed
5. Transcribed text still sent via the existing REST `sendInput` path

### Phase 4: Full-Duplex / Advanced

**Goal:** Natural conversational voice, speaking and listening simultaneously.

Options to evaluate:
- **OpenAI Realtime API** — simplest path to full-duplex, but $0.30/min and ties you to OpenAI
- **LiveKit Agents** — open-source WebRTC infrastructure with Swift SDK, Python agent framework. Better for production at scale. [agent-starter-swift](https://github.com/livekit-examples/agent-starter-swift) as starting point.
- **Pipecat** — open-source Python pipeline framework, maximum flexibility in swapping STT/LLM/TTS providers

This phase would likely involve the voice channel understanding agent context (not just relaying text) — e.g., the voice model interprets terminal output semantically and responds conversationally rather than reading raw text.

---

## Alternatives Considered

### OpenAI Realtime API (all-in-one)

- Single API for STT + reasoning + TTS + VAD + interruption handling
- Sub-300ms latency via WebRTC transport
- Supports function calling (could trigger agent actions directly)
- **Rejected for phase 1** because: $0.30/min is 10x the cascaded pipeline cost, ties voice to OpenAI's models, and we want voice as a transport layer over existing tmux sessions, not a separate AI reasoning path
- **Reconsidered for phase 4** if we want the voice channel to be a smart conversational interface rather than just a relay

### Cartesia Sonic-3 (TTS)

- 40ms TTFA — fastest in industry
- Fine-grained emotion/speed control
- Slightly more expensive than ElevenLabs ($0.038 vs $0.030-0.050 per 1K chars)
- **Not chosen** because ElevenLabs' WebSocket streaming API is more mature and the 75ms vs 40ms TTFA difference is imperceptible in practice

### AssemblyAI Universal-Streaming (STT)

- 300ms P50 latency, semantic endpointing
- $0.0025/min — cheapest option
- **Caveat:** Charged for entire WebSocket session duration (idle time included), not just audio minutes
- Good alternative to Deepgram if we find their endpointing superior in practice

### Direct-to-cloud from iOS (no agent relay)

- iOS app connects directly to Deepgram/ElevenLabs
- **Rejected** because: API keys would need to ship to client (or proxy auth adds complexity anyway), can't diff pane output without agent involvement, splits the audio pipeline across two systems

---

## Key Risks

| Risk | Mitigation |
|------|------------|
| Audio latency over Tailscale VPN | Opus codec reduces bandwidth 70%; small 20ms frames; measure RTT and set latency budget |
| React Native audio limitations | May need native modules for AVAudioEngine/Opus; `expo-av` covers basics but low-level streaming may require bridging |
| Terminal output is noisy for TTS | Strip ANSI codes, filter progress bars/spinners, only speak "meaningful" new output (heuristic or LLM-based filtering) |
| Cost at scale | Push-to-talk naturally limits minutes; add usage tracking and daily caps in agent config |
| Deepgram/ElevenLabs outages | Graceful degradation to on-device (WhisperKit + AVSpeechSynthesizer) |
| Background audio on iOS | Apple restricts background audio; PushToTalk framework helps but adds complexity |

---

## References

- [Deepgram Nova-3](https://deepgram.com/learn/introducing-nova-3-speech-to-text-api) — streaming STT
- [ElevenLabs WebSocket API](https://elevenlabs.io/docs/api-reference/text-to-speech/v-1-text-to-speech-voice-id-stream-input) — streaming TTS
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device Whisper for iOS
- [Silero VAD](https://github.com/snakers4/silero-vad) — voice activity detection
- [RealTimeCutVADLibrary](https://github.com/helloooideeeeea/RealTimeCutVADLibrary) — Silero VAD iOS wrapper
- [Apple PushToTalk Framework](https://developer.apple.com/documentation/PushToTalk) — system-level PTT
- [LiveKit Agents](https://github.com/livekit/agents) — open-source voice AI framework
- [LiveKit Swift SDK](https://github.com/livekit/client-sdk-swift) — iOS WebRTC client
- [Pipecat](https://github.com/pipecat-ai/pipecat) — open-source voice pipeline framework
- [OpenAI Realtime API](https://platform.openai.com/docs/guides/realtime) — full-duplex voice AI
- [The Voice AI Stack for Building Agents (AssemblyAI)](https://www.assemblyai.com/blog/the-voice-ai-stack-for-building-agents)
