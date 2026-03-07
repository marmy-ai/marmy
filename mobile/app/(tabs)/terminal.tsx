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
} from "react-native";
import Slider from "@react-native-community/slider";
import * as Haptics from "expo-haptics";
import { useNavigation } from "expo-router";
import { useConnectionStore } from "../../src/stores/connectionStore";
import { useSessionStore } from "../../src/stores/sessionStore";

const CHAT_SHORTCUT_KEYS = [
  { label: "Ctrl-C", value: "\x03" },
  { label: "Tab", value: "\t" },
  { label: "\u2191", value: "\x1b[A" },
  { label: "\u2193", value: "\x1b[B" },
  { label: "y", value: "y\n" },
  { label: "n", value: "n\n" },
];

// KB mode: 2-row fixed grid — arrows grouped as d-pad on the right
const KB_GRID_ROW1 = [
  { label: "Esc", value: "\x1b" },
  { label: "Tab", value: "\t" },
  { label: "Ctrl", value: "__CTRL__" },
  { label: "DEL", value: "\x7f" },
  { label: "\u2191", value: "\x1b[A" },
];

const KB_GRID_ROW2 = [
  { label: "CR", value: "\n" },
  { label: "MSG", value: "__MSG__" },
  { label: "\u2190", value: "\x1b[D" },
  { label: "\u2192", value: "\x1b[C" },
  { label: "\u2193", value: "\x1b[B" },
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

  // Set the nav header title to the session name
  useEffect(() => {
    navigation.setOptions({ title: activeSessionName || "Terminal" });
  }, [activeSessionName, navigation]);
  const [content, setContent] = useState("");
  const [inputText, setInputText] = useState("");
  const [isKeyboardMode, setIsKeyboardMode] = useState(false);
  const [ctrlActive, setCtrlActive] = useState(false);
  const [inputHeight, setInputHeight] = useState(40);
  const scrollRef = useRef<ScrollView>(null);
  const isScrolledUp = useRef(false);
  const prevTextRef = useRef("");
  const lastContentRef = useRef("");
  const [termCols, setTermCols] = useState(DEFAULT_COLS);

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
          Go to Sessions and tap a pane to view.
        </Text>
      </View>
    );
  }

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      keyboardVerticalOffset={100}
    >
      {/* Toolbar: notify toggle + width slider */}
      <View style={styles.toolbar}>
        <TouchableOpacity
          activeOpacity={0.7}
          style={styles.notifySection}
          onPress={async () => {
            const next = !notifyOnDone;
            setNotifyOnDone(next);
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            try {
              await api?.setNotifyHook(next);
            } catch {}
          }}
        >
          <View style={[styles.toggleTrack, notifyOnDone && styles.toggleTrackActive]}>
            <View style={[styles.toggleThumb, notifyOnDone && styles.toggleThumbActive]} />
          </View>
          <Text style={[styles.notifyLabel, notifyOnDone && styles.notifyLabelActive]}>
            Notify
          </Text>
        </TouchableOpacity>

        <View style={styles.widthSection}>
          <Slider
            style={styles.widthSlider}
            minimumValue={MIN_COLS}
            maximumValue={MAX_COLS}
            step={COLS_STEP}
            value={termCols}
            onValueChange={(v) => setTermCols(v)}
            minimumTrackTintColor="#7c3aed"
            maximumTrackTintColor="#2a2a3e"
            thumbImage={require("../../assets/slider-thumb.png")}
          />
          <Text style={styles.widthLabel}>{termCols}</Text>
        </View>
      </View>

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
        <View style={styles.kbGrid}>
          <View style={styles.kbRow}>
            {KB_GRID_ROW1.map((key) => (
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
            {KB_GRID_ROW2.map((key) => (
              <TouchableOpacity
                key={key.label}
                style={styles.kbBtn}
                onPress={() => handleShortcut(key.value)}
              >
                <Text style={styles.kbBtnText}>{key.label}</Text>
              </TouchableOpacity>
            ))}
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
      <View style={styles.inputBar}>
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
          ]}
          value={inputText}
          onChangeText={handleChangeText}
          multiline={!isKeyboardMode}
          onContentSizeChange={(e) => {
            if (!isKeyboardMode) {
              const h = Math.min(e.nativeEvent.contentSize.height, MAX_INPUT_HEIGHT);
              setInputHeight(Math.max(40, h));
            }
          }}
          placeholder={isKeyboardMode ? "Keys sent live..." : "Type command..."}
          placeholderTextColor="#555"
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
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#0f0f1a" },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: "#0f0f1a",
  },
  emptyText: { color: "#888", fontSize: 18, marginBottom: 8 },
  emptySubtext: { color: "#555", fontSize: 14 },
  toolbar: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 12,
    height: 36,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
    backgroundColor: "#0f0f1a",
    gap: 8,
  },
  notifySection: {
    flexDirection: "row",
    alignItems: "center",
    gap: 6,
  },
  widthSection: {
    flexDirection: "row",
    alignItems: "center",
    marginLeft: "auto",
    gap: 2,
  },
  widthSlider: {
    width: 120,
    height: 28,
  },
  widthLabel: {
    color: "#888",
    fontSize: 11,
    fontFamily: "monospace",
    width: 24,
    textAlign: "right",
  },
  terminalScroll: {
    flex: 1,
    backgroundColor: "#0f0f1a",
  },
  terminalContent: {
    padding: 8,
  },
  terminalTextContainer: {
    color: "#e0e0e0",
    fontSize: 11,
    fontFamily: Platform.OS === "ios" ? "Menlo" : "monospace",
    lineHeight: 16,
  },
  terminalText: {
    color: "#e0e0e0",
    fontSize: 11,
    fontFamily: Platform.OS === "ios" ? "Menlo" : "monospace",
    lineHeight: 16,
  },
  terminalLine: {
    // Inherits from parent Text
  },
  promptSeparator: {
    borderTopWidth: 1,
    borderTopColor: "#2a2a3e",
    marginTop: 6,
    paddingTop: 4,
  },
  // Chat mode shortcut bar (horizontal scroll)
  shortcutBar: {
    maxHeight: 40,
    borderTopWidth: 1,
    borderTopColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
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
    backgroundColor: "#2a2a3e",
  },
  shortcutBtnText: { color: "#ccc", fontSize: 13, fontFamily: "monospace" },
  // KB mode fixed grid
  kbGrid: {
    borderTopWidth: 1,
    borderTopColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
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
    backgroundColor: "#2a2a3e",
    alignItems: "center",
    justifyContent: "center",
  },
  kbBtnActive: {
    backgroundColor: "#7c3aed",
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
  toggleTrack: {
    width: 36,
    height: 20,
    borderRadius: 10,
    backgroundColor: "#2a2a3e",
    justifyContent: "center",
    paddingHorizontal: 2,
  },
  toggleTrackActive: {
    backgroundColor: "#7c3aed",
  },
  toggleThumb: {
    width: 16,
    height: 16,
    borderRadius: 8,
    backgroundColor: "#555",
  },
  toggleThumbActive: {
    backgroundColor: "#fff",
    alignSelf: "flex-end",
  },
  notifyLabel: {
    color: "#555",
    fontSize: 13,
    fontWeight: "500",
  },
  notifyLabelActive: {
    color: "#c4b5fd",
  },
  // Input bar
  inputBar: {
    flexDirection: "row",
    padding: 8,
    gap: 8,
    borderTopWidth: 1,
    borderTopColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
    alignItems: "flex-end",
  },
  textInput: {
    flex: 1,
    backgroundColor: "#0f0f1a",
    borderWidth: 1,
    borderColor: "#2a2a3e",
    borderRadius: 8,
    padding: 10,
    color: "#e0e0e0",
    fontSize: 15,
    fontFamily: "monospace",
  },
  sendBtn: {
    backgroundColor: "#7c3aed",
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
    backgroundColor: "#2a2a3e",
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
    backgroundColor: "#7c3aed",
  },
  segmentText: {
    color: "#888",
    fontSize: 13,
    fontWeight: "700",
    fontFamily: "monospace",
  },
  segmentTextActive: {
    color: "#fff",
  },
});
