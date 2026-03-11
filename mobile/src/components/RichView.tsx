import React from "react";
import {
  View,
  Text,
  ScrollView,
  StyleSheet,
} from "react-native";
import { theme } from "../theme";

interface RichViewProps {
  content: string;
}

/**
 * Rich view renders terminal output with basic markdown-style formatting.
 *
 * MVP implementation: splits output into code blocks and text blocks,
 * applying basic styling. Full markdown rendering (react-native-markdown-display)
 * and syntax highlighting (react-native-syntax-highlighter) are wired up as
 * dependencies and can be integrated when the Claude Code stream-json parser
 * is connected.
 */
export default function RichView({ content }: RichViewProps) {
  const blocks = parseBlocks(content);

  return (
    <ScrollView style={styles.container} contentContainerStyle={styles.content}>
      {blocks.map((block, i) => {
        if (block.type === "code") {
          return (
            <View key={i} style={styles.codeBlock}>
              {block.language ? (
                <Text style={styles.codeLang}>{block.language}</Text>
              ) : null}
              <ScrollView horizontal showsHorizontalScrollIndicator>
                <Text style={styles.codeText}>{block.content}</Text>
              </ScrollView>
            </View>
          );
        }

        if (block.type === "heading") {
          return (
            <Text key={i} style={styles.heading}>
              {block.content}
            </Text>
          );
        }

        return (
          <Text key={i} style={styles.text}>
            {block.content}
          </Text>
        );
      })}
    </ScrollView>
  );
}

interface Block {
  type: "text" | "code" | "heading";
  content: string;
  language?: string;
}

function parseBlocks(content: string): Block[] {
  const blocks: Block[] = [];
  const lines = content.split("\n");
  let i = 0;
  let currentText: string[] = [];

  const flushText = () => {
    if (currentText.length > 0) {
      const text = currentText.join("\n").trim();
      if (text) {
        blocks.push({ type: "text", content: text });
      }
      currentText = [];
    }
  };

  while (i < lines.length) {
    const line = lines[i];

    // Detect fenced code blocks
    const codeMatch = line.match(/^```(\w*)/);
    if (codeMatch) {
      flushText();
      const language = codeMatch[1] || undefined;
      const codeLines: string[] = [];
      i++;
      while (i < lines.length && !lines[i].startsWith("```")) {
        codeLines.push(lines[i]);
        i++;
      }
      blocks.push({
        type: "code",
        content: codeLines.join("\n"),
        language,
      });
      i++; // skip closing ```
      continue;
    }

    // Detect headings
    const headingMatch = line.match(/^(#{1,3})\s+(.+)/);
    if (headingMatch) {
      flushText();
      blocks.push({ type: "heading", content: headingMatch[2] });
      i++;
      continue;
    }

    currentText.push(line);
    i++;
  }

  flushText();
  return blocks;
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#0f0f1a" },
  content: { padding: 16 },
  text: {
    color: "#d0d0d0",
    fontSize: 15,
    lineHeight: 22,
    marginBottom: 12,
  },
  heading: {
    color: "#e0e0e0",
    fontSize: 20,
    fontWeight: "700",
    marginBottom: 8,
    marginTop: 16,
  },
  codeBlock: {
    backgroundColor: "#1a1a2e",
    borderRadius: 8,
    padding: 12,
    marginBottom: 12,
    borderWidth: 1,
    borderColor: "#2a2a3e",
  },
  codeLang: {
    color: theme.primary,
    fontSize: 11,
    fontWeight: "600",
    marginBottom: 6,
    textTransform: "uppercase",
  },
  codeText: {
    color: "#e0e0e0",
    fontSize: 13,
    fontFamily: 'Menlo, Monaco, "Courier New", monospace',
    lineHeight: 18,
  },
});
