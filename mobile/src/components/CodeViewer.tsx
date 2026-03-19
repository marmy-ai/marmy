import React from "react";
import {
  View,
  Text,
  ScrollView,
  StyleSheet,
} from "react-native";
import SyntaxHighlighter from "react-native-syntax-highlighter";
import { atomOneDark } from "react-syntax-highlighter/dist/esm/styles/hljs";

interface CodeViewerProps {
  content: string;
  filename: string;
  highlightLine?: number;
}

const PLAIN_TEXT_THRESHOLD = 2000;

const EXT_TO_LANGUAGE: Record<string, string> = {
  js: "javascript",
  mjs: "javascript",
  cjs: "javascript",
  jsx: "javascript",
  ts: "typescript",
  tsx: "typescript",
  py: "python",
  rb: "ruby",
  rs: "rust",
  go: "go",
  java: "java",
  kt: "kotlin",
  kts: "kotlin",
  swift: "swift",
  c: "c",
  h: "c",
  cpp: "cpp",
  cc: "cpp",
  hpp: "cpp",
  cs: "csharp",
  css: "css",
  scss: "scss",
  less: "less",
  html: "xml",
  htm: "xml",
  xml: "xml",
  svg: "xml",
  json: "json",
  yaml: "yaml",
  yml: "yaml",
  toml: "ini",
  md: "markdown",
  mdx: "markdown",
  sh: "bash",
  bash: "bash",
  zsh: "bash",
  fish: "bash",
  sql: "sql",
  graphql: "graphql",
  gql: "graphql",
  dockerfile: "dockerfile",
  makefile: "makefile",
  lua: "lua",
  r: "r",
  php: "php",
  pl: "perl",
  ex: "elixir",
  exs: "elixir",
  erl: "erlang",
  hs: "haskell",
  clj: "clojure",
  scala: "scala",
  dart: "dart",
  vue: "xml",
  svelte: "xml",
};

function detectLanguage(filename: string): string | undefined {
  const lower = filename.toLowerCase();
  // Handle dotfiles like Dockerfile, Makefile
  const base = lower.split("/").pop() || lower;
  if (base === "dockerfile") return "dockerfile";
  if (base === "makefile") return "makefile";

  const ext = base.split(".").pop();
  if (!ext || ext === base) return undefined;
  return EXT_TO_LANGUAGE[ext];
}

export default function CodeViewer({
  content,
  filename,
  highlightLine,
}: CodeViewerProps) {
  const lines = content.split("\n");
  const language = detectLanguage(filename);
  const useSyntaxHighlighting = language && lines.length <= PLAIN_TEXT_THRESHOLD;

  if (useSyntaxHighlighting) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <Text style={styles.filename} numberOfLines={1}>
            {filename}
          </Text>
          <Text style={styles.lineCount}>{lines.length} lines</Text>
        </View>
        <ScrollView style={styles.scroll}>
          <SyntaxHighlighter
            language={language}
            style={atomOneDark}
            fontSize={13}
            fontFamily="Menlo"
            highlighter="hljs"
            customStyle={{
              backgroundColor: "transparent",
              padding: 8,
            }}
          >
            {content}
          </SyntaxHighlighter>
        </ScrollView>
      </View>
    );
  }

  // Fallback: plain text with line numbers (for large files or unknown languages)
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
