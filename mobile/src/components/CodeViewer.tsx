import React from "react";
import {
  View,
  Text,
  ScrollView,
  StyleSheet,
} from "react-native";

interface CodeViewerProps {
  content: string;
  filename: string;
  highlightLine?: number;
}

/**
 * Read-only code viewer with line numbers.
 *
 * MVP: renders plain monospace text with line numbers. For syntax highlighting,
 * integrate react-native-syntax-highlighter (already in package.json) keyed on
 * the file extension. For large files (>5K lines), swap to CodeMirror 6 in a
 * WebView with readOnly: true for virtualized rendering.
 */
export default function CodeViewer({
  content,
  filename,
  highlightLine,
}: CodeViewerProps) {
  const lines = content.split("\n");
  const gutterWidth = String(lines.length).length * 10 + 16;

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.filename} numberOfLines={1}>
          {filename}
        </Text>
        <Text style={styles.lineCount}>{lines.length} lines</Text>
      </View>

      <ScrollView style={styles.scroll}>
        <ScrollView horizontal showsHorizontalScrollIndicator>
          <View>
            {lines.map((line, i) => {
              const lineNum = i + 1;
              const isHighlighted = lineNum === highlightLine;
              return (
                <View
                  key={i}
                  style={[
                    styles.lineRow,
                    isHighlighted && styles.lineHighlighted,
                  ]}
                >
                  <Text
                    style={[styles.lineNumber, { width: gutterWidth }]}
                  >
                    {lineNum}
                  </Text>
                  <Text style={styles.lineText}>{line}</Text>
                </View>
              );
            })}
          </View>
        </ScrollView>
      </ScrollView>
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#0f0f1a" },
  header: {
    flexDirection: "row",
    justifyContent: "space-between",
    alignItems: "center",
    padding: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
  },
  filename: { color: "#e0e0e0", fontSize: 14, fontFamily: "monospace", flex: 1 },
  lineCount: { color: "#555", fontSize: 12 },
  scroll: { flex: 1, padding: 4 },
  lineRow: {
    flexDirection: "row",
    minHeight: 20,
  },
  lineHighlighted: {
    backgroundColor: "rgba(124, 58, 237, 0.15)",
  },
  lineNumber: {
    color: "#555",
    fontSize: 13,
    fontFamily: "monospace",
    textAlign: "right",
    paddingRight: 12,
    userSelect: "none",
  },
  lineText: {
    color: "#d0d0d0",
    fontSize: 13,
    fontFamily: "monospace",
    lineHeight: 20,
  },
});
