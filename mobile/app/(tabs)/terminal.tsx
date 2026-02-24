import React, { useRef, useEffect, useState, useCallback } from "react";
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
import TerminalView, {
  TerminalHandle,
} from "../../src/components/TerminalView";
import RichView from "../../src/components/RichView";

const SHORTCUT_KEYS = [
  { label: "Tab", value: "\t" },
  { label: "Esc", value: "\x1b" },
  { label: "Ctrl-C", value: "\x03" },
  { label: "Ctrl-D", value: "\x04" },
  { label: "Up", value: "\x1b[A" },
  { label: "Down", value: "\x1b[B" },
  { label: "y", value: "y\n" },
];

export default function TerminalScreen() {
  const { socket, api, connected } = useConnectionStore();
  const { activePaneId, viewMode, setViewMode } = useSessionStore();
  const terminalRef = useRef<TerminalHandle | null>(null);
  const [inputText, setInputText] = useState("");
  const [rawContent, setRawContent] = useState("");

  // Subscribe to active pane's output
  useEffect(() => {
    if (!socket || !activePaneId) return;

    socket.subscribePane(activePaneId);

    const unsub = socket.onMessage((msg) => {
      if (msg.type === "pane_output" && msg.pane_id === activePaneId) {
        // Feed data to xterm.js
        terminalRef.current?.write(msg.data);
        // Accumulate for rich view
        setRawContent((prev) => prev + msg.data);
      }
    });

    // Fetch existing content
    if (api) {
      api.getPaneContent(activePaneId).then((content) => {
        terminalRef.current?.write(content.content);
        setRawContent(content.content);
      }).catch(() => {});
    }

    return () => {
      unsub();
      socket.unsubscribePane(activePaneId);
    };
  }, [socket, activePaneId, api]);

  const handleInput = useCallback(
    (data: string) => {
      if (socket && activePaneId) {
        socket.sendInput(activePaneId, data);
      }
    },
    [socket, activePaneId]
  );

  const handleResize = useCallback(
    (cols: number, rows: number) => {
      if (socket && activePaneId) {
        socket.resizePane(activePaneId, cols, rows);
      }
    },
    [socket, activePaneId]
  );

  const handleSend = () => {
    if (inputText.trim() && socket && activePaneId) {
      socket.sendInput(activePaneId, inputText + "\n");
      setInputText("");
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

  return (
    <KeyboardAvoidingView
      style={styles.container}
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      keyboardVerticalOffset={100}
    >
      {/* Mode toggle */}
      <View style={styles.modeBar}>
        <TouchableOpacity
          style={[styles.modeBtn, viewMode === "raw" && styles.modeBtnActive]}
          onPress={() => setViewMode("raw")}
        >
          <Text
            style={[
              styles.modeBtnText,
              viewMode === "raw" && styles.modeBtnTextActive,
            ]}
          >
            Raw
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={[styles.modeBtn, viewMode === "rich" && styles.modeBtnActive]}
          onPress={() => setViewMode("rich")}
        >
          <Text
            style={[
              styles.modeBtnText,
              viewMode === "rich" && styles.modeBtnTextActive,
            ]}
          >
            Rich
          </Text>
        </TouchableOpacity>
      </View>

      {/* Terminal / Rich content */}
      <View style={styles.content}>
        {viewMode === "raw" ? (
          <TerminalView
            terminalRef={terminalRef}
            onInput={handleInput}
            onResize={handleResize}
          />
        ) : (
          <RichView content={rawContent} />
        )}
      </View>

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
            onPress={() => handleInput(key.value)}
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
  modeBar: {
    flexDirection: "row",
    padding: 8,
    gap: 8,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
  },
  modeBtn: {
    paddingHorizontal: 16,
    paddingVertical: 6,
    borderRadius: 6,
    backgroundColor: "#1a1a2e",
  },
  modeBtnActive: { backgroundColor: "#7c3aed" },
  modeBtnText: { color: "#888", fontSize: 14, fontWeight: "500" },
  modeBtnTextActive: { color: "#fff" },
  content: { flex: 1 },
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
