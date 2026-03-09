import {
  initialize,
  playPCMData,
  toggleRecording,
  tearDown,
  bypassVoiceProcessing,
  requestMicrophonePermissionsAsync,
  addExpoTwoWayAudioEventListener,
} from "@speechmatics/expo-two-way-audio";
import type { MarmyApi } from "./api";

export type VoiceState =
  | "idle"
  | "connecting"
  | "listening"
  | "model_speaking"
  | "error";

const GEMINI_WS_URL =
  "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent";

const SYSTEM_PROMPT = `You are a voice assistant connected to an active terminal session where Claude Code is already running. The user is hands-free — they may be running, driving, or otherwise unable to type. Your primary job is to act as an intermediary: the user speaks to you, you relay their instructions to Claude Code by typing into the terminal, and you report back what Claude Code is doing.

IMPORTANT: Claude Code is ALREADY running in this terminal. NEVER run "claude", "claude --dangerously-skip-permissions", or any command to start or restart Claude Code. It is already active. If the terminal appears to show a regular shell prompt without Claude Code, simply ask the user what they'd like to do — do NOT launch Claude Code yourself.

Claude Code is an AI coding agent CLI. It reads files, writes code, runs commands, and modifies codebases. It accepts natural language instructions typed into the terminal. When you relay the user's request, just type the instruction and press Enter.

You can see the terminal screen via periodic TERMINAL UPDATE messages. When you receive one, note significant changes: Claude Code finished a task, encountered an error, is asking a question, or a process is waiting for input. Proactively tell the user about these. When Claude Code asks a question or needs clarification, relay it to the user immediately so they can respond through you.

You have one tool: write_to_shell. It sends text to the terminal and presses Enter. ONLY use it when the user explicitly asks you to run or type something. Never execute commands on your own. When relaying the user's words to Claude Code, type their message verbatim or rephrase it clearly.

Keep responses concise — you're in a voice conversation. Summarize terminal output rather than reading it verbatim. If the user asks "what's happening", describe the current state in 1-2 sentences. Focus on what went wrong and what to do about it, not file paths or stack traces.

If the terminal shows something waiting for input (y/n prompt, password, or Claude Code asking a question), tell the user immediately.

When the session starts, greet the user by saying "How can I help you?".`;

const SETUP_MESSAGE = {
  setup: {
    model: "models/gemini-2.5-flash-native-audio-preview-12-2025",
    generationConfig: {
      responseModalities: ["AUDIO"],
      speechConfig: {
        voiceConfig: {
          prebuiltVoiceConfig: { voiceName: "Kore" },
        },
      },
    },
    systemInstruction: {
      parts: [{ text: SYSTEM_PROMPT }],
    },
    tools: [
      {
        functionDeclarations: [
          {
            name: "write_to_shell",
            description:
              "Send text input to the active terminal session. Appends a newline to submit the command. Only call this when the user has confirmed or clearly asked you to execute something.",
            parameters: {
              type: "object",
              properties: {
                text: {
                  type: "string",
                  description: "The text/command to type into the terminal",
                },
              },
              required: ["text"],
            },
          },
        ],
      },
    ],
    realtimeInputConfig: {
      automaticActivityDetection: {
        disabled: true,
      },
    },
  },
};

interface VoiceSessionConfig {
  geminiApiKey: string;
  api: MarmyApi;
  paneId: string;
  onStateChange: (state: VoiceState) => void;
}

// Uint8Array (16-bit LE PCM) to base64
function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary);
}

// Base64 to Uint8Array
function base64ToBytes(base64: string): Uint8Array {
  const binaryString = atob(base64);
  const bytes = new Uint8Array(binaryString.length);
  for (let i = 0; i < binaryString.length; i++) {
    bytes[i] = binaryString.charCodeAt(i);
  }
  return bytes;
}

// Resample 16-bit LE PCM from 24kHz to 16kHz using linear interpolation
function resample24kTo16k(input: Uint8Array): Uint8Array {
  const int16In = new Int16Array(input.buffer, input.byteOffset, input.length / 2);
  const ratio = 24000 / 16000; // 1.5
  const outLength = Math.floor(int16In.length / ratio);
  const int16Out = new Int16Array(outLength);

  for (let i = 0; i < outLength; i++) {
    const srcIdx = i * ratio;
    const idx = Math.floor(srcIdx);
    const frac = srcIdx - idx;
    const s0 = int16In[idx];
    const s1 = idx + 1 < int16In.length ? int16In[idx + 1] : s0;
    int16Out[i] = Math.round(s0 + frac * (s1 - s0));
  }

  return new Uint8Array(int16Out.buffer);
}

export class VoiceSession {
  private config: VoiceSessionConfig;

  // Connection
  private ws: WebSocket | null = null;
  private sessionResumptionHandle: string | null = null;
  private setupComplete = false;

  // Audio
  private micSubscription: { remove: () => void } | null = null;
  private eventSubscriptions: { remove: () => void }[] = [];

  // Context injection
  private contextInterval: ReturnType<typeof setInterval> | null = null;
  private lastPaneContent = "";
  private modelSpeaking = false;

  // State
  private active = false;
  private state: VoiceState = "idle";
  private reconnectCount = 0;
  private static MAX_RECONNECTS = 5;

  constructor(config: VoiceSessionConfig) {
    this.config = config;
  }

  async start(): Promise<void> {
    if (this.active) return;
    this.active = true;
    this.setState("connecting");

    // Request mic permissions
    const { granted } = await requestMicrophonePermissionsAsync();
    if (!granted) {
      console.error("[Voice] Mic permission denied");
      this.setState("error");
      this.active = false;
      return;
    }

    // Initialize audio engine
    await initialize();

    this.openWebSocket();
  }

  async stop(): Promise<void> {
    this.active = false;
    this.setState("idle");

    // Stop mic
    this.stopAudioCapture();

    // Stop context injection
    if (this.contextInterval) {
      clearInterval(this.contextInterval);
      this.contextInterval = null;
    }

    // Close WebSocket
    if (this.ws) {
      this.ws.close();
      this.ws = null;
    }

    this.setupComplete = false;
    tearDown();
  }

  isActive(): boolean {
    return this.active;
  }

  /** Call when user presses the talk button */
  pushToTalkStart() {
    if (!this.ws || !this.setupComplete) return;
    toggleRecording(true);
    this.ws.send(JSON.stringify({
      realtimeInput: { activityStart: {} },
    }));
    console.log("[Voice] PTT start");
  }

  /** Call when user releases the talk button */
  pushToTalkEnd() {
    if (!this.ws || !this.setupComplete) return;
    this.ws.send(JSON.stringify({
      realtimeInput: { activityEnd: {} },
    }));
    toggleRecording(false);
    console.log("[Voice] PTT end");
  }

  private setState(state: VoiceState) {
    this.state = state;
    this.config.onStateChange(state);
  }

  private openWebSocket() {
    const url = `${GEMINI_WS_URL}?key=${this.config.geminiApiKey}`;
    this.ws = new WebSocket(url);

    this.ws.onopen = () => {
      const setup = { ...SETUP_MESSAGE };
      if (this.sessionResumptionHandle) {
        (setup.setup as any).sessionResumption = {
          handle: this.sessionResumptionHandle,
        };
      }
      this.ws?.send(JSON.stringify(setup));
    };

    this.ws.onmessage = async (event) => {
      try {
        let text: string;
        const raw = event.data;
        if (typeof raw === "string") {
          text = raw;
        } else if (raw instanceof Blob) {
          text = await raw.text();
        } else if (raw instanceof ArrayBuffer) {
          text = new TextDecoder().decode(raw);
        } else {
          return;
        }
        const data = JSON.parse(text);
        this.handleServerMessage(data);
      } catch (e) {
        console.warn("[Voice] Failed to parse message:", e);
      }
    };

    this.ws.onerror = (e) => {
      console.error("[Voice] WebSocket error:", e);
      if (this.active) this.setState("error");
    };

    this.ws.onclose = (e) => {
      console.log("[Voice] WebSocket closed:", e.code, e.reason);
      if (!this.active) return;
      if (e.code === 1007 || e.code === 1008 || e.code === 4003) {
        this.setState("error");
        return;
      }
      if (this.reconnectCount >= VoiceSession.MAX_RECONNECTS) {
        console.error("[Voice] Max reconnects reached, giving up");
        this.setState("error");
        return;
      }
      this.reconnectCount++;
      setTimeout(() => {
        if (this.active) {
          this.setState("connecting");
          this.openWebSocket();
        }
      }, 2000);
    };
  }

  private handleServerMessage(data: any) {
    if (data.setupComplete !== undefined) {
      this.setupComplete = true;
      this.reconnectCount = 0;
      console.log("[Voice] Setup complete, starting capture");
      this.setState("listening");
      this.startAudioCapture();
      this.startContextInjection();
      this.injectContext();
    } else if (data.sessionResumptionUpdate) {
      if (data.sessionResumptionUpdate.newHandle) {
        this.sessionResumptionHandle = data.sessionResumptionUpdate.newHandle;
      }
    } else if (data.serverContent) {
      if (data.serverContent.modelTurn?.parts) {
        for (const part of data.serverContent.modelTurn.parts) {
          if (part.inlineData) {
            if (this.state !== "model_speaking") {
              this.setState("model_speaking");
            }
            this.modelSpeaking = true;
            this.handleAudioData(part.inlineData.data);
          }
        }
      }
      if (data.serverContent.turnComplete) {
        this.modelSpeaking = false;
        this.setState("listening");
      }
      if (data.serverContent.interrupted) {
        this.modelSpeaking = false;
        this.setState("listening");
      }
    } else if (data.toolCall) {
      this.handleToolCall(data.toolCall);
    } else if (data.goAway) {
      this.handleGoAway();
    }
  }

  // --- Audio Capture ---

  private startAudioCapture() {
    if (this.micSubscription) return;

    // Listen for audio interruptions (track for cleanup)
    this.eventSubscriptions.push(
      addExpoTwoWayAudioEventListener("onAudioInterruption", (event) => {
        console.log("[Voice] Audio interruption:", event.data);
      })
    );

    this.eventSubscriptions.push(
      addExpoTwoWayAudioEventListener("onRecordingChange", (event) => {
        console.log("[Voice] Recording state changed:", event.data);
      })
    );

    bypassVoiceProcessing(true);

    // Subscribe to mic data events — delivers 16kHz 16-bit mono PCM as Uint8Array
    this.micSubscription = addExpoTwoWayAudioEventListener(
      "onMicrophoneData",
      (event) => {
        if (!this.ws || !this.setupComplete || !this.active) return;
        const base64 = bytesToBase64(event.data);
        this.ws.send(
          JSON.stringify({
            realtimeInput: {
              audio: {
                mimeType: "audio/pcm;rate=16000",
                data: base64,
              },
            },
          })
        );
      }
    );

    console.log("[Voice] Mic listener ready, waiting for PTT");
  }

  private stopAudioCapture() {
    try { toggleRecording(false); } catch {}
    if (this.micSubscription) {
      this.micSubscription.remove();
      this.micSubscription = null;
    }
    for (const sub of this.eventSubscriptions) {
      sub.remove();
    }
    this.eventSubscriptions = [];
  }

  // --- Audio Playback ---

  private handleAudioData(base64Pcm: string) {
    // Gemini sends 24kHz 16-bit mono PCM, expo-two-way-audio plays 16kHz
    const raw24k = base64ToBytes(base64Pcm);
    const resampled16k = resample24kTo16k(raw24k);
    playPCMData(resampled16k);
  }

  // --- Context Injection ---

  private startContextInjection() {
    if (this.contextInterval) return;
    this.contextInterval = setInterval(() => {
      if (this.modelSpeaking) return;
      this.injectContext();
    }, 7000);
  }

  private async injectContext() {
    try {
      const { content } = await this.config.api.getPaneContent(
        this.config.paneId
      );
      if (content === this.lastPaneContent) return;
      this.lastPaneContent = content;

      const lines = content.split("\n");
      const trimmed = lines.slice(-100).join("\n");

      this.ws?.send(
        JSON.stringify({
          clientContent: {
            turns: [
              {
                role: "user",
                parts: [
                  {
                    text: `--- TERMINAL UPDATE ---\n${trimmed}\n--- END TERMINAL ---`,
                  },
                ],
              },
            ],
            turnComplete: true,
          },
        })
      );
    } catch {}
  }

  // --- Tool Calls ---

  private handleToolCall(toolCall: any) {
    for (const fn of toolCall.functionCalls) {
      if (fn.name === "write_to_shell") {
        this.config.api
          .sendInput(this.config.paneId, fn.args.text + "\n")
          .catch(() => {});

        this.ws?.send(
          JSON.stringify({
            toolResponse: {
              functionResponses: [
                {
                  response: { success: true },
                  id: fn.id,
                },
              ],
            },
          })
        );

        setTimeout(() => this.injectContext(), 1500);
      }
    }
  }

  // --- Session Resumption ---

  private handleGoAway() {
    this.stopAudioCapture();
    this.ws?.close();
    this.ws = null;
    this.setupComplete = false;

    if (this.active) {
      this.setState("connecting");
      this.openWebSocket();
    }
  }
}
