import React, { useRef, useEffect, useState } from "react";
import {
  View,
  Text,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  KeyboardAvoidingView,
  Platform,
  ScrollView,
} from "react-native";
import { useConnectionStore } from "../../src/stores/connectionStore";
import { useSessionStore } from "../../src/stores/sessionStore";

const CHAT_SHORTCUT_KEYS = [
  { label: "Ctrl-C", value: "\x03" },
  { label: "Tab", value: "\t" },
  { label: "Up", value: "\x1b[A" },
  { label: "Down", value: "\x1b[B" },
  { label: "y", value: "y\n" },
  { label: "n", value: "n\n" },
];

const KEYBOARD_SHORTCUT_KEYS = [
  { label: "Esc", value: "\x1b" },
  { label: "Ctrl-C", value: "\x03" },
  { label: "Ctrl-D", value: "\x04" },
  { label: "Ctrl-Z", value: "\x1a" },
  { label: "Ctrl-A", value: "\x01" },
  { label: "Ctrl-E", value: "\x05" },
  { label: "Tab", value: "\t" },
  { label: "\u2190", value: "\x1b[D" },
  { label: "\u2192", value: "\x1b[C" },
  { label: "\u2191", value: "\x1b[A" },
  { label: "\u2193", value: "\x1b[B" },
];

export default function TerminalScreen() {
  const { api, connected } = useConnectionStore();
  const { activePaneId } = useSessionStore();
  const [content, setContent] = useState("");
  const [inputText, setInputText] = useState("");
  const [isKeyboardMode, setIsKeyboardMode] = useState(false);
  const scrollRef = useRef<ScrollView>(null);
  const isScrolledUp = useRef(false);
  const prevTextRef = useRef("");

  // Poll pane history (full scrollback) every 500ms
  useEffect(() => {
    if (!api || !activePaneId) return;

    let active = true;
    const poll = async () => {
      try {
        const result = await api.getPaneHistory(activePaneId);
        if (active) setContent(result.content);
      } catch {}
    };

    poll();
    const interval = setInterval(poll, 500);
    return () => {
      active = false;
      clearInterval(interval);
    };
  }, [api, activePaneId]);

  // Auto-scroll to bottom on new content, but only if user hasn't scrolled up
  useEffect(() => {
    if (!isScrolledUp.current) {
      setTimeout(() => scrollRef.current?.scrollToEnd({ animated: false }), 50);
    }
  }, [content]);

  // Reset TextInput when switching to keyboard mode
  useEffect(() => {
    if (isKeyboardMode) {
      setInputText("");
      prevTextRef.current = "";
    }
  }, [isKeyboardMode]);

  const handleSend = async () => {
    if (!inputText.trim() || !api || !activePaneId) return;
    // Undo iOS smart punctuation: em/en dashes back to --, smart quotes back to plain
    const text = inputText
      .replace(/\u2014/g, "--")  // em dash → --
      .replace(/\u2013/g, "-")   // en dash → -
      .replace(/[\u201C\u201D]/g, '"')  // smart double quotes
      .replace(/[\u2018\u2019]/g, "'"); // smart single quotes
    setInputText("");
    try {
      await api.sendInput(activePaneId, text + "\n");
    } catch {}
  };

  const handleShortcut = async (value: string) => {
    if (!api || !activePaneId) return;
    try {
      await api.sendInput(activePaneId, value);
    } catch {}
  };

  const handleChangeText = (newText: string) => {
    if (!isKeyboardMode) {
      setInputText(newText);
      return;
    }

    if (!api || !activePaneId) return;

    const prev = prevTextRef.current;

    if (newText.length > prev.length) {
      // Characters added — send the new characters
      const added = newText.slice(prev.length);
      // Undo iOS smart punctuation
      const cleaned = added
        .replace(/\u2014/g, "--")
        .replace(/\u2013/g, "-")
        .replace(/[\u201C\u201D]/g, '"')
        .replace(/[\u2018\u2019]/g, "'");
      api.sendInput(activePaneId, cleaned).catch(() => {});
    } else if (newText.length < prev.length) {
      // Characters deleted — send DEL for each removed character
      const deletedCount = prev.length - newText.length;
      const delSequence = "\x7f".repeat(deletedCount);
      api.sendInput(activePaneId, delSequence).catch(() => {});
    }

    // Clear the input after each keystroke so it stays empty
    prevTextRef.current = "";
    setInputText("");
  };

  const handleSubmitEditing = () => {
    if (isKeyboardMode) {
      if (!api || !activePaneId) return;
      api.sendInput(activePaneId, "\n").catch(() => {});
    } else {
      handleSend();
    }
  };

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

  const shortcuts = isKeyboardMode ? KEYBOARD_SHORTCUT_KEYS : CHAT_SHORTCUT_KEYS;

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      keyboardVerticalOffset={100}
    >
      {/* Terminal content — plain text, polled */}
      <ScrollView
        ref={scrollRef}
        style={styles.terminalScroll}
        contentContainerStyle={styles.terminalContent}
        onScroll={(e) => {
          const { layoutMeasurement, contentOffset, contentSize } = e.nativeEvent;
          const distanceFromBottom = contentSize.height - layoutMeasurement.height - contentOffset.y;
          isScrolledUp.current = distanceFromBottom > 50;
        }}
        scrollEventThrottle={100}
      >
        <Text style={styles.terminalText} selectable>
          {content}
        </Text>
      </ScrollView>

      {/* Shortcut bar */}
      <ScrollView
        horizontal
        style={styles.shortcutBar}
        contentContainerStyle={styles.shortcutContent}
        showsHorizontalScrollIndicator={false}
      >
        {shortcuts.map((key) => (
          <TouchableOpacity
            key={key.label}
            style={styles.shortcutBtn}
            onPress={() => handleShortcut(key.value)}
          >
            <Text style={styles.shortcutBtnText}>{key.label}</Text>
          </TouchableOpacity>
        ))}
      </ScrollView>

      {/* Input bar */}
      <View style={styles.inputBar}>
        <TouchableOpacity
          style={[styles.modeToggle, isKeyboardMode && styles.modeToggleActive]}
          onPress={() => setIsKeyboardMode((prev) => !prev)}
        >
          <Text style={[styles.modeToggleText, isKeyboardMode && styles.modeToggleTextActive]}>
            {isKeyboardMode ? "KB" : "MSG"}
          </Text>
        </TouchableOpacity>
        <TextInput
          style={styles.textInput}
          value={inputText}
          onChangeText={handleChangeText}
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
  terminalScroll: {
    flex: 1,
    backgroundColor: "#0f0f1a",
  },
  terminalContent: {
    padding: 8,
  },
  terminalText: {
    color: "#e0e0e0",
    fontSize: 11,
    fontFamily: Platform.OS === "ios" ? "Menlo" : "monospace",
    lineHeight: 15,
  },
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
  inputBar: {
    flexDirection: "row",
    padding: 8,
    gap: 8,
    borderTopWidth: 1,
    borderTopColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
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
  },
  sendBtnText: { color: "#fff", fontSize: 15, fontWeight: "600" },
  modeToggle: {
    paddingHorizontal: 12,
    borderRadius: 8,
    justifyContent: "center",
    backgroundColor: "#2a2a3e",
  },
  modeToggleActive: {
    backgroundColor: "#7c3aed",
  },
  modeToggleText: {
    color: "#888",
    fontSize: 13,
    fontWeight: "700",
    fontFamily: "monospace",
  },
  modeToggleTextActive: {
    color: "#fff",
  },
});
