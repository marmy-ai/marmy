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

const SHORTCUT_KEYS = [
  { label: "Ctrl-C", value: "\x03" },
  { label: "Tab", value: "\t" },
  { label: "Up", value: "\x1b[A" },
  { label: "Down", value: "\x1b[B" },
  { label: "y", value: "y\n" },
  { label: "n", value: "n\n" },
];

export default function TerminalScreen() {
  const { api, connected } = useConnectionStore();
  const { activePaneId } = useSessionStore();
  const [content, setContent] = useState("");
  const [inputText, setInputText] = useState("");
  const scrollRef = useRef<ScrollView>(null);

  // Poll pane content every 500ms
  useEffect(() => {
    if (!api || !activePaneId) return;

    let active = true;
    const poll = async () => {
      try {
        const result = await api.getPaneContent(activePaneId);
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

  // Auto-scroll to bottom on new content
  useEffect(() => {
    setTimeout(() => scrollRef.current?.scrollToEnd({ animated: false }), 50);
  }, [content]);

  const handleSend = async () => {
    if (!inputText.trim() || !api || !activePaneId) return;
    try {
      await api.sendInput(activePaneId, inputText + "\n");
      setInputText("");
    } catch {}
  };

  const handleShortcut = async (value: string) => {
    if (!api || !activePaneId) return;
    try {
      await api.sendInput(activePaneId, value);
    } catch {}
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
        {SHORTCUT_KEYS.map((key) => (
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
        <TextInput
          style={styles.textInput}
          value={inputText}
          onChangeText={setInputText}
          placeholder="Type command..."
          placeholderTextColor="#555"
          autoCapitalize="none"
          autoCorrect={false}
          returnKeyType="send"
          onSubmitEditing={handleSend}
        />
        <TouchableOpacity style={styles.sendBtn} onPress={handleSend}>
          <Text style={styles.sendBtnText}>Send</Text>
        </TouchableOpacity>
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
});
