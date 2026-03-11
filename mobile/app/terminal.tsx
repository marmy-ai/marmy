import React, { useRef, useEffect, useState, useMemo } from "react";
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  KeyboardAvoidingView,
  Keyboard,
  Platform,
  ScrollView,
  AppState,
} from "react-native";
import Slider from "@react-native-community/slider";
import * as Haptics from "expo-haptics";
import { useNavigation } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useHeaderHeight } from "@react-navigation/elements";
import { Ionicons } from "@expo/vector-icons";
import { useConnectionStore } from "../src/stores/connectionStore";
import { useSessionStore } from "../src/stores/sessionStore";
import { VoiceSession } from "../src/services/voiceSession";
import { theme } from "../src/theme";
import type { VoiceState } from "../src/services/voiceSession";
import VoiceCallBar from "../src/components/VoiceCallBar";

const CHAT_SHORTCUT_KEYS = [
  { label: "Ctrl-C", value: "\x03" },
  { label: "\u23CE", value: "\n" },
  { label: "Tab", value: "\t" },
  { label: "\u2191", value: "\x1b[A" },
  { label: "\u2193", value: "\x1b[B" },
  { label: "y", value: "y\n" },
  { label: "n", value: "n\n" },
];

// KB mode page 1: 2-row fixed grid — arrows grouped as d-pad on the right
const KB_P1_ROW1 = [
  { label: "Esc", value: "\x1b" },
  { label: "Tab", value: "\t" },
  { label: "Ctrl", value: "__CTRL__" },
  { label: "DEL", value: "\x7f" },
  { label: "\u2191", value: "\x1b[A" },
];

const KB_P1_ROW2 = [
  { label: "\u23CE", value: "\n" },
  { label: "MSG", value: "__MSG__" },
  { label: "\u2190", value: "\x1b[D" },
  { label: "\u2192", value: "\x1b[C" },
  { label: "\u2193", value: "\x1b[B" },
];

// KB mode page 2: extra keys accessible by swiping
const KB_P2_ROW1 = [
  { label: "CR", value: "\n" },
  { label: "S-Tab", value: "\x1b[Z" },
];

const DEFAULT_COLS = 60;
const DEFAULT_ROWS = 50;
const MIN_COLS = 40;
const MAX_COLS = 200;
const COLS_STEP = 10;

// --- ANSI parser ---

interface AnsiSpan {
  text: string;
  bold?: boolean;
  dim?: boolean;
  italic?: boolean;
  color?: string;
}

const ANSI_FG: Record<number, string> = {
  30: "#555", 31: "#e06c75", 32: "#98c379", 33: "#e5c07b",
  34: "#61afef", 35: "#c678dd", 36: "#56b6c2", 37: "#abb2bf",
  90: "#5c6370", 91: "#e06c75", 92: "#98c379", 93: "#e5c07b",
  94: "#61afef", 95: "#c678dd", 96: "#56b6c2", 97: "#ffffff",
};

function parseAnsi(raw: string): AnsiSpan[] {
  // Strip all non-SGR escape sequences (cursor movement, erase, etc.)
  const stripped = raw.replace(/\x1b\[[0-9;]*[A-HJKSTfhln]/g, "")
                      .replace(/\x1b\][^\x07]*\x07/g, "")   // OSC sequences
                      .replace(/\x1b\[[\?]?[0-9;]*[a-z]/gi, function(m) {
                        // Keep only SGR (ending in 'm')
                        return m.endsWith("m") ? m : "";
                      });

  const spans: AnsiSpan[] = [];
  const regex = /\x1b\[([0-9;]*)m/g;
  let lastIndex = 0;
  let bold = false, dim = false, italic = false, underline = false;
  let color: string | undefined;

  let match: RegExpExecArray | null;
  while ((match = regex.exec(stripped)) !== null) {
    if (match.index > lastIndex) {
      spans.push({ text: stripped.slice(lastIndex, match.index), bold, dim, italic, color });
    }
    const codes = match[1] ? match[1].split(";").map(Number) : [0];
    let i = 0;
    while (i < codes.length) {
      const code = codes[i];
      if (code === 0) { bold = false; dim = false; italic = false; underline = false; color = undefined; }
      else if (code === 1) bold = true;
      else if (code === 2) dim = true;
      else if (code === 3) italic = true;
      else if (code === 4) underline = true;
      else if (code === 22) { bold = false; dim = false; }
      else if (code === 23) italic = false;
      else if (code === 24) underline = false;
      else if (ANSI_FG[code]) color = ANSI_FG[code];
      else if (code === 39) color = undefined;
      // 256-color: ESC[38;5;Nm
      else if (code === 38 && codes[i + 1] === 5) {
        const n = codes[i + 2];
        if (n !== undefined && n >= 0 && n <= 255) {
          color = ansi256ToHex(n);
        }
        i += 2;
      }
      // Skip background color codes (40-49, 100-107, 48;5;N)
      else if (code === 48 && codes[i + 1] === 5) { i += 2; }
      i++;
    }
    lastIndex = regex.lastIndex;
  }
  if (lastIndex < stripped.length) {
    spans.push({ text: stripped.slice(lastIndex), bold, dim, italic, color });
  }
  return spans;
}

// Basic 256-color palette to hex
function ansi256ToHex(n: number): string {
  // Standard 16 colors
  const base16: string[] = [
    "#000", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#abb2bf",
    "#5c6370", "#e06c75", "#98c379", "#e5c07b", "#61afef", "#c678dd", "#56b6c2", "#fff",
  ];
  if (n < 16) return base16[n];
  if (n >= 232) { // Grayscale
    const v = 8 + (n - 232) * 10;
    return `rgb(${v},${v},${v})`;
  }
  // 216-color cube (16-231)
  const idx = n - 16;
  const r = Math.floor(idx / 36) * 51;
  const g = Math.floor((idx % 36) / 6) * 51;
  const b = (idx % 6) * 51;
  return `rgb(${r},${g},${b})`;
}

// --- Prompt boundary detection ---

function renderContent(content: string) {
  // Strip any remaining ANSI escape sequences that aren't SGR (colors/styles)
  const cleaned = content.replace(/\x1b\[[0-9;]*[A-HJKSTfn]/g, "");

  const lines = cleaned.split("\n");
  const elements: React.ReactNode[] = [];
  const promptRegex = /^[>$] /;

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const isPrompt = promptRegex.test(line);

    if (isPrompt && i > 0) {
      elements.push(
        <View key={`sep-${i}`} style={styles.promptSeparator} />
      );
    }

    const spans = parseAnsi(line);
    elements.push(
      <Text key={`line-${i}`} style={styles.terminalLine}>
        {spans.map((span, j) => (
          <Text
            key={j}
            style={[
              styles.terminalText,
              span.bold && { fontWeight: "700" as const },
              span.dim && { opacity: 0.5 },
              span.italic && { fontStyle: "italic" as const },
              span.color ? { color: span.color } : undefined,
            ]}
          >
            {span.text}
          </Text>
        ))}
        {"\n"}
      </Text>
    );
  }

  return elements;
}

export default function TerminalScreen() {
  const { api, socket, connected } = useConnectionStore();
  const { activePaneId, activeSessionName, notifyOnDone, setNotifyOnDone } = useSessionStore();
  const navigation = useNavigation();
  const insets = useSafeAreaInsets();
  const headerHeight = useHeaderHeight();

  // Set the nav header title to the session name
  useEffect(() => {
    navigation.setOptions({ title: activeSessionName || "Terminal" });
  }, [activeSessionName, navigation]);
  const [content, setContent] = useState("");
  const [inputText, setInputText] = useState("");
  const [isKeyboardMode, setIsKeyboardMode] = useState(false);
  const [ctrlActive, setCtrlActive] = useState(false);
  const [kbPage, setKbPage] = useState(0);
  const kbSwipeRef = useRef({ x: 0, y: 0 });
  const [inputHeight, setInputHeight] = useState(40);
  const scrollRef = useRef<ScrollView>(null);
  const isScrolledUp = useRef(false);
  const prevTextRef = useRef("");
  const lastContentRef = useRef("");
  const [termCols, setTermCols] = useState(DEFAULT_COLS);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const [keyboardVisible, setKeyboardVisible] = useState(false);

  // Track keyboard visibility to conditionally apply bottom safe area
  useEffect(() => {
    const showSub = Keyboard.addListener("keyboardWillShow", () => setKeyboardVisible(true));
    const hideSub = Keyboard.addListener("keyboardWillHide", () => setKeyboardVisible(false));
    return () => { showSub.remove(); hideSub.remove(); };
  }, []);

  // Voice mode
  const [voiceActive, setVoiceActive] = useState(false);
  const [voiceState, setVoiceState] = useState<VoiceState>("idle");
  const voiceSessionRef = useRef<VoiceSession | null>(null);
  const [pendingInstruction, setPendingInstruction] = useState<string | null>(null);
  const pendingResolveRef = useRef<((approved: boolean) => void) | null>(null);

  // Cleanup voice on unmount
  useEffect(() => {
    return () => {
      voiceSessionRef.current?.stop();
    };
  }, []);

  // Stop voice when app goes to background
  useEffect(() => {
    const sub = AppState.addEventListener("change", (nextState) => {
      if (nextState !== "active" && voiceSessionRef.current) {
        voiceSessionRef.current.stop();
        voiceSessionRef.current = null;
        setVoiceState("idle");
        setVoiceActive(false);
      }
    });
    return () => sub.remove();
  }, []);

  const startVoice = async () => {
    if (!api || !activePaneId) return;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    setVoiceActive(true);
    setVoiceState("connecting");
    try {
      const { token } = await api.getVoiceToken();
      console.log("[Voice] Got token, connecting to Gemini...");
      const session = new VoiceSession({
        geminiApiKey: token,
        api,
        paneId: activePaneId,
        sessionName: activeSessionName || "default",
        onStateChange: setVoiceState,
        onInstructionPending: (text: string) =>
          new Promise<boolean>((resolve) => {
            setPendingInstruction(text);
            pendingResolveRef.current = resolve;
          }),
      });
      voiceSessionRef.current = session;
      await session.start();
    } catch (e) {
      console.error("[Voice] Failed to start:", e);
      setVoiceState("error");
    }
  };

  const stopVoice = async () => {
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
    // Decline any pending instruction on stop
    pendingResolveRef.current?.(false);
    pendingResolveRef.current = null;
    setPendingInstruction(null);
    await voiceSessionRef.current?.stop();
    voiceSessionRef.current = null;
    setVoiceState("idle");
    setVoiceActive(false);
  };

  // Resize the tmux window whenever pane or cols changes
  useEffect(() => {
    if (!socket || !activePaneId) return;
    socket.resizePane(activePaneId, termCols, DEFAULT_ROWS);
  }, [socket, activePaneId, termCols]);

  const MAX_INPUT_HEIGHT = 120;
  // Padding character so KB mode always has something for backspace to delete
  const KB_PAD = " ";

  // Sync notify toggle with agent on mount
  useEffect(() => {
    if (!api) return;
    api.getNotifyHookStatus().then(setNotifyOnDone).catch(() => {});
  }, [api]);

  // Subscribe to pane output via WebSocket
  useEffect(() => {
    if (!socket || !activePaneId) return;

    socket.subscribePane(activePaneId);

    const unsub = socket.onMessage((msg) => {
      if (msg.type === "pane_output" && msg.pane_id === activePaneId) {
        if (msg.data !== lastContentRef.current) {
          lastContentRef.current = msg.data;
          setContent(msg.data);
        }
      }
    });

    return () => {
      socket.unsubscribePane(activePaneId);
      unsub();
    };
  }, [socket, activePaneId]);

  // Auto-scroll to bottom on new content, but only if user hasn't scrolled up
  useEffect(() => {
    if (!isScrolledUp.current) {
      setTimeout(() => scrollRef.current?.scrollToEnd({ animated: false }), 50);
    }
  }, [content]);


  // Reset TextInput when switching to keyboard mode
  useEffect(() => {
    if (isKeyboardMode) {
      setInputText(KB_PAD);
      prevTextRef.current = KB_PAD;
      setCtrlActive(false);
    }
  }, [isKeyboardMode]);

  // Reset input height when switching modes
  useEffect(() => {
    if (isKeyboardMode) {
      setInputHeight(40);
    }
  }, [isKeyboardMode]);

  const handleSend = () => {
    if (!inputText.trim() || !socket || !activePaneId) return;
    const text = inputText
      .replace(/\u2014/g, "--")
      .replace(/\u2013/g, "-")
      .replace(/[\u201C\u201D]/g, '"')
      .replace(/[\u2018\u2019]/g, "'");
    setInputText("");
    setInputHeight(40);
    socket.sendInput(activePaneId, text + "\n");
  };

  const handleShortcut = (value: string) => {
    if (value === "__CTRL__") {
      setCtrlActive((prev) => !prev);
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      return;
    }
    if (value === "__MSG__") {
      setIsKeyboardMode(false);
      Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
      return;
    }

    if (!socket || !activePaneId) return;
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
    socket.sendInput(activePaneId, value);
  };

  const handleChangeText = (newText: string) => {
    if (!isKeyboardMode) {
      setInputText(newText);
      return;
    }

    if (!socket || !activePaneId) return;

    const prev = prevTextRef.current;

    if (newText.length > prev.length) {
      const added = newText.slice(prev.length);
      const cleaned = added
        .replace(/\u2014/g, "--")
        .replace(/\u2013/g, "-")
        .replace(/[\u201C\u201D]/g, '"')
        .replace(/[\u2018\u2019]/g, "'");

      if (ctrlActive) {
        for (const ch of cleaned) {
          const upper = ch.toUpperCase();
          const code = upper.charCodeAt(0) - 64;
          if (code >= 1 && code <= 26) {
            socket.sendInput(activePaneId, String.fromCharCode(code));
          }
        }
        setCtrlActive(false);
      } else {
        socket.sendInput(activePaneId, cleaned);
      }
    } else if (newText.length < prev.length) {
      const deletedCount = prev.length - newText.length;
      const delSequence = "\x7f".repeat(deletedCount);
      socket.sendInput(activePaneId, delSequence);
    }

    prevTextRef.current = KB_PAD;
    setInputText(KB_PAD);
  };

  const handleSubmitEditing = () => {
    if (isKeyboardMode) {
      if (!socket || !activePaneId) return;
      socket.sendInput(activePaneId, "\n");
    } else {
      handleSend();
    }
  };

  const renderedContent = useMemo(() => {
    // Strip trailing blank lines (tmux pane includes full screen height of empty lines)
    const lines = content.split("\n");
    while (lines.length > 0 && lines[lines.length - 1].trim() === "") {
      lines.pop();
    }
    // Cap lines to prevent OOM on large scrollback buffers
    const MAX_LINES = 500;
    const capped = lines.length > MAX_LINES ? lines.slice(-MAX_LINES) : lines;
    return renderContent(capped.join("\n"));
  }, [content]);

  if (!connected) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyText}>Not connected.</Text>
      </View>
    );
  }

  if (!activePaneId) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyText}>No pane selected.</Text>
        <Text style={styles.emptySubtext}>
          Go to Workers and tap Chat to view.
        </Text>
      </View>
    );
  }

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      keyboardVerticalOffset={headerHeight}
    >
      {/* Toolbar */}
      <View style={styles.toolbar}>
        <TouchableOpacity
          style={styles.callButton}
          onPress={voiceActive ? stopVoice : startVoice}
          hitSlop={{ top: 8, bottom: 8, left: 8, right: 8 }}
        >
          <Ionicons
            name="call-outline"
            size={22}
            color={voiceActive ? theme.error : theme.textSecondary}
            style={voiceActive ? { transform: [{ rotate: "135deg" }] } : undefined}
          />
        </TouchableOpacity>

        <TouchableOpacity
          activeOpacity={0.7}
          style={[styles.settingsButton, settingsOpen && styles.settingsButtonActive]}
          onPress={() => {
            setSettingsOpen((prev) => !prev);
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
          }}
        >
          <Ionicons
            name={settingsOpen ? "settings" : "settings-outline"}
            size={20}
            color={settingsOpen ? "#fff" : theme.textSecondary}
          />
        </TouchableOpacity>
      </View>

      {/* Settings panel */}
      {settingsOpen && (
        <View style={styles.settingsPanel}>
          <TouchableOpacity
            activeOpacity={0.7}
            style={styles.settingsRow}
            onPress={async () => {
              const next = !notifyOnDone;
              setNotifyOnDone(next);
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              try {
                await api?.setNotifyHook(next);
              } catch {}
            }}
          >
            <Text style={styles.settingsLabel}>Notify on done</Text>
            <View style={[styles.toggleTrack, notifyOnDone && styles.toggleTrackActive]}>
              <View style={[styles.toggleThumb, notifyOnDone && styles.toggleThumbActive]} />
            </View>
          </TouchableOpacity>

          <View style={styles.settingsRow}>
            <Text style={styles.settingsLabel}>Width</Text>
            <Slider
              style={styles.settingsSlider}
              minimumValue={MIN_COLS}
              maximumValue={MAX_COLS}
              step={COLS_STEP}
              value={termCols}
              onValueChange={(v) => setTermCols(v)}
              minimumTrackTintColor={theme.primary}
              maximumTrackTintColor={theme.border}
              thumbImage={require("../assets/slider-thumb.png")}
            />
            <Text style={styles.settingsValue}>{termCols}</Text>
          </View>
        </View>
      )}

      {/* Terminal content with ANSI rendering */}
      <ScrollView
        ref={scrollRef}
        style={styles.terminalScroll}
        contentContainerStyle={styles.terminalContent}
        keyboardDismissMode="on-drag"
        onTouchStart={() => Keyboard.dismiss()}

        onScroll={(e) => {
          const { layoutMeasurement, contentOffset, contentSize } = e.nativeEvent;
          const distanceFromBottom = contentSize.height - layoutMeasurement.height - contentOffset.y;
          isScrolledUp.current = distanceFromBottom > 50;
        }}
        scrollEventThrottle={100}
      >
        <Text selectable style={styles.terminalTextContainer}>
          {renderedContent}
        </Text>
      </ScrollView>

      {/* Shortcut bar */}
      {isKeyboardMode ? (
        <View
          style={styles.kbGrid}
          onTouchStart={(e) => {
            kbSwipeRef.current = { x: e.nativeEvent.pageX, y: e.nativeEvent.pageY };
          }}
          onTouchEnd={(e) => {
            const dx = e.nativeEvent.pageX - kbSwipeRef.current.x;
            const dy = e.nativeEvent.pageY - kbSwipeRef.current.y;
            if (Math.abs(dx) > 40 && Math.abs(dx) > Math.abs(dy)) {
              if (dx < 0 && kbPage === 0) setKbPage(1);
              else if (dx > 0 && kbPage === 1) setKbPage(0);
            }
          }}
        >
          {kbPage === 0 ? (
            <>
              <View style={styles.kbRow}>
                {KB_P1_ROW1.map((key) => (
                  <TouchableOpacity
                    key={key.label}
                    style={[
                      styles.kbBtn,
                      key.value === "__CTRL__" && ctrlActive && styles.kbBtnActive,
                    ]}
                    onPress={() => handleShortcut(key.value)}
                  >
                    <Text style={[
                      styles.kbBtnText,
                      key.value === "__CTRL__" && ctrlActive && styles.kbBtnTextActive,
                    ]}>
                      {key.label}
                    </Text>
                  </TouchableOpacity>
                ))}
              </View>
              <View style={styles.kbRow}>
                {KB_P1_ROW2.map((key) => (
                  <TouchableOpacity
                    key={key.label}
                    style={styles.kbBtn}
                    onPress={() => handleShortcut(key.value)}
                  >
                    <Text style={styles.kbBtnText}>{key.label}</Text>
                  </TouchableOpacity>
                ))}
              </View>
            </>
          ) : (
            <View style={styles.kbRow}>
              {KB_P2_ROW1.map((key) => (
                <TouchableOpacity
                  key={key.label}
                  style={styles.kbBtn}
                  onPress={() => handleShortcut(key.value)}
                >
                  <Text style={styles.kbBtnText}>{key.label}</Text>
                </TouchableOpacity>
              ))}
            </View>
          )}
          {/* Page indicator */}
          <View style={styles.kbPageDots}>
            <View style={[styles.kbDot, kbPage === 0 && styles.kbDotActive]} />
            <View style={[styles.kbDot, kbPage === 1 && styles.kbDotActive]} />
          </View>
        </View>
      ) : (
        <ScrollView
          horizontal
          style={styles.shortcutBar}
          contentContainerStyle={styles.shortcutContent}
          showsHorizontalScrollIndicator={false}
        >
          {CHAT_SHORTCUT_KEYS.map((key) => (
            <TouchableOpacity
              key={key.label}
              style={styles.shortcutBtn}
              onPress={() => handleShortcut(key.value)}
            >
              <Text style={styles.shortcutBtnText}>{key.label}</Text>
            </TouchableOpacity>
          ))}
        </ScrollView>
      )}

      {/* Input bar */}
      <View style={[styles.inputBar, !keyboardVisible && { paddingBottom: Math.max(8, insets.bottom) }]}>
        {/* Segmented mode toggle */}
        <View style={styles.segmentedToggle}>
          <TouchableOpacity
            style={[
              styles.segment,
              styles.segmentLeft,
              !isKeyboardMode && styles.segmentActive,
            ]}
            onPress={() => setIsKeyboardMode(false)}
          >
            <Text style={[
              styles.segmentText,
              !isKeyboardMode && styles.segmentTextActive,
            ]}>
              MSG
            </Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[
              styles.segment,
              styles.segmentRight,
              isKeyboardMode && styles.segmentActive,
            ]}
            onPress={() => setIsKeyboardMode(true)}
          >
            <Text style={[
              styles.segmentText,
              isKeyboardMode && styles.segmentTextActive,
            ]}>
              KB
            </Text>
          </TouchableOpacity>
        </View>

        <TextInput
          style={[
            styles.textInput,
            !isKeyboardMode && { height: inputHeight },
            voiceActive && { opacity: 0.4 },
          ]}
          value={inputText}
          onChangeText={handleChangeText}
          editable={!voiceActive}
          multiline={!isKeyboardMode}
          onContentSizeChange={(e) => {
            if (!isKeyboardMode) {
              const h = Math.min(e.nativeEvent.contentSize.height, MAX_INPUT_HEIGHT);
              setInputHeight(Math.max(40, h));
            }
          }}
          placeholder={voiceActive ? "Voice mode active..." : isKeyboardMode ? "Keys sent live..." : "Type command..."}
          placeholderTextColor={theme.textTertiary}
          autoCapitalize="none"
          autoCorrect={false}
          autoComplete="off"
          spellCheck={false}
          textContentType="none"
          returnKeyType={isKeyboardMode ? "default" : "send"}
          onSubmitEditing={handleSubmitEditing}
          blurOnSubmit={!isKeyboardMode}
        />
        {!isKeyboardMode && (
          <TouchableOpacity style={styles.sendBtn} onPress={handleSend}>
            <Text style={styles.sendBtnText}>Send</Text>
          </TouchableOpacity>
        )}
      </View>
      {/* Floating voice call overlay */}
      {voiceActive && (
        <View style={styles.voiceOverlayWrapper} pointerEvents="box-none">
          <VoiceCallBar
            state={voiceState}
            onEnd={stopVoice}
            onMicOn={() => voiceSessionRef.current?.pushToTalkStart()}
            onMicOff={() => voiceSessionRef.current?.pushToTalkEnd()}
            pendingInstruction={pendingInstruction}
            onApprove={() => {
              pendingResolveRef.current?.(true);
              pendingResolveRef.current = null;
              setPendingInstruction(null);
            }}
            onDecline={() => {
              pendingResolveRef.current?.(false);
              pendingResolveRef.current = null;
              setPendingInstruction(null);
            }}
          />
        </View>
      )}
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: theme.bgDeep },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: theme.bgDeep,
  },
  emptyText: { color: theme.textSecondary, fontSize: 18, marginBottom: 8 },
  emptySubtext: { color: theme.textTertiary, fontSize: 14 },
  toolbar: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 12,
    height: 44,
    borderBottomWidth: 1,
    borderBottomColor: theme.border,
    backgroundColor: theme.bgDeep,
  },
  settingsButton: {
    width: 32,
    height: 32,
    borderRadius: 8,
    backgroundColor: theme.border,
    alignItems: "center",
    justifyContent: "center",
  },
  settingsButtonActive: {
    backgroundColor: theme.primary,
  },
  callButton: {
    padding: 4,
  },
  settingsPanel: {
    borderBottomWidth: 1,
    borderBottomColor: theme.border,
    backgroundColor: theme.bgElevated,
    paddingHorizontal: 16,
    paddingVertical: 10,
    gap: 12,
  },
  settingsRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
  },
  settingsLabel: {
    color: "#aaa",
    fontSize: 14,
  },
  settingsSlider: {
    flex: 1,
    height: 28,
    marginHorizontal: 12,
  },
  settingsValue: {
    color: theme.textSecondary,
    fontSize: 13,
    fontFamily: "monospace",
    width: 28,
    textAlign: "right",
  },
  terminalScroll: {
    flex: 1,
    backgroundColor: theme.bgDeep,
  },
  terminalContent: {
    padding: 8,
  },
  terminalTextContainer: {
    color: theme.textPrimary,
    fontSize: 11,
    fontFamily: Platform.OS === "ios" ? "Menlo" : "monospace",
    lineHeight: 16,
  },
  terminalText: {
    color: theme.textPrimary,
    fontSize: 11,
    fontFamily: Platform.OS === "ios" ? "Menlo" : "monospace",
    lineHeight: 16,
  },
  terminalLine: {
    // Inherits from parent Text
  },
  promptSeparator: {
    borderTopWidth: 1,
    borderTopColor: theme.border,
    marginTop: 6,
    paddingTop: 4,
  },
  // Chat mode shortcut bar (horizontal scroll)
  shortcutBar: {
    maxHeight: 40,
    borderTopWidth: 1,
    borderTopColor: theme.border,
    backgroundColor: theme.bgCard,
  },
  shortcutContent: {
    alignItems: "center",
    paddingHorizontal: 8,
    gap: 6,
  },
  shortcutBtn: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 4,
    backgroundColor: theme.border,
  },
  shortcutBtnText: { color: "#ccc", fontSize: 13, fontFamily: "monospace" },
  // KB mode fixed grid
  kbGrid: {
    borderTopWidth: 1,
    borderTopColor: theme.border,
    backgroundColor: theme.bgCard,
    paddingVertical: 4,
    paddingHorizontal: 4,
  },
  kbRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginVertical: 2,
  },
  kbBtn: {
    flex: 1,
    marginHorizontal: 2,
    paddingVertical: 8,
    borderRadius: 4,
    backgroundColor: theme.border,
    alignItems: "center",
    justifyContent: "center",
  },
  kbBtnActive: {
    backgroundColor: theme.primary,
  },
  kbBtnText: {
    color: "#ccc",
    fontSize: 13,
    fontFamily: "monospace",
    fontWeight: "600",
  },
  kbBtnTextActive: {
    color: "#fff",
  },
  kbPageDots: {
    flexDirection: "row",
    justifyContent: "center",
    gap: 6,
    paddingTop: 4,
    paddingBottom: 2,
  },
  kbDot: {
    width: 6,
    height: 6,
    borderRadius: 3,
    backgroundColor: theme.border,
  },
  kbDotActive: {
    backgroundColor: theme.primary,
  },
  toggleTrack: {
    width: 36,
    height: 20,
    borderRadius: 10,
    backgroundColor: theme.border,
    justifyContent: "center",
    paddingHorizontal: 2,
  },
  toggleTrackActive: {
    backgroundColor: theme.primary,
  },
  toggleThumb: {
    width: 16,
    height: 16,
    borderRadius: 8,
    backgroundColor: theme.textTertiary,
  },
  toggleThumbActive: {
    backgroundColor: "#fff",
    alignSelf: "flex-end",
  },
  // Input bar
  inputBar: {
    flexDirection: "row",
    padding: 8,
    gap: 8,
    borderTopWidth: 1,
    borderTopColor: theme.border,
    backgroundColor: theme.bgCard,
    alignItems: "flex-end",
  },
  textInput: {
    flex: 1,
    backgroundColor: theme.bgDeep,
    borderWidth: 1,
    borderColor: theme.border,
    borderRadius: 8,
    padding: 10,
    color: theme.textPrimary,
    fontSize: 15,
    fontFamily: "monospace",
  },
  sendBtn: {
    backgroundColor: theme.primary,
    paddingHorizontal: 16,
    borderRadius: 8,
    justifyContent: "center",
    height: 40,
  },
  sendBtnText: { color: "#fff", fontSize: 15, fontWeight: "600" },
  // Segmented mode toggle
  segmentedToggle: {
    flexDirection: "row",
    borderRadius: 8,
    overflow: "hidden",
    height: 40,
  },
  segment: {
    paddingHorizontal: 10,
    justifyContent: "center",
    alignItems: "center",
    backgroundColor: theme.border,
  },
  segmentLeft: {
    borderTopLeftRadius: 8,
    borderBottomLeftRadius: 8,
  },
  segmentRight: {
    borderTopRightRadius: 8,
    borderBottomRightRadius: 8,
  },
  segmentActive: {
    backgroundColor: theme.primary,
  },
  segmentText: {
    color: theme.textSecondary,
    fontSize: 13,
    fontWeight: "700",
    fontFamily: "monospace",
  },
  segmentTextActive: {
    color: "#fff",
  },
  voiceOverlayWrapper: {
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    bottom: 0,
    justifyContent: "flex-end",
    alignItems: "center",
    paddingBottom: 160,
  },
});
