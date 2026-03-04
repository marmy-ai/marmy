import React, { useMemo } from "react";
import { View, Text, StyleSheet } from "react-native";
import { WebView } from "react-native-webview";
import { marked } from "marked";

interface MarkdownViewerProps {
  content: string;
  filename: string;
}

export default function MarkdownViewer({ content, filename }: MarkdownViewerProps) {
  const html = useMemo(() => {
    const body = marked.parse(content) as string;
    return `<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=3">
<style>
  * { box-sizing: border-box; }
  body {
    font-family: -apple-system, system-ui, sans-serif;
    background: #0f0f1a;
    color: #d0d0d0;
    padding: 16px;
    margin: 0;
    line-height: 1.6;
    font-size: 15px;
  }
  h1, h2, h3, h4, h5, h6 {
    color: #e0e0e0;
    margin-top: 24px;
    margin-bottom: 8px;
  }
  h1 { font-size: 1.6em; border-bottom: 1px solid #2a2a3e; padding-bottom: 8px; }
  h2 { font-size: 1.4em; border-bottom: 1px solid #2a2a3e; padding-bottom: 6px; }
  a { color: #7c3aed; text-decoration: none; }
  code {
    background: #1a1a2e;
    padding: 2px 6px;
    border-radius: 4px;
    font-family: monospace;
    font-size: 0.9em;
  }
  pre {
    background: #1a1a2e;
    padding: 12px;
    border-radius: 6px;
    overflow-x: auto;
    border: 1px solid #2a2a3e;
  }
  pre code { background: none; padding: 0; }
  blockquote {
    border-left: 3px solid #7c3aed;
    margin-left: 0;
    padding-left: 12px;
    color: #999;
  }
  table {
    border-collapse: collapse;
    width: 100%;
    margin: 12px 0;
  }
  th, td {
    border: 1px solid #2a2a3e;
    padding: 8px 12px;
    text-align: left;
  }
  th { background: #1a1a2e; color: #e0e0e0; }
  img { max-width: 100%; border-radius: 6px; }
  hr { border: none; border-top: 1px solid #2a2a3e; margin: 16px 0; }
  ul, ol { padding-left: 24px; }
  li { margin-bottom: 4px; }
  input[type="checkbox"] { margin-right: 6px; }
</style>
</head>
<body>${body}</body>
</html>`;
  }, [content]);

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.filename} numberOfLines={1}>
          {filename}
        </Text>
      </View>
      <WebView
        source={{ html }}
        style={styles.webview}
        javaScriptEnabled={false}
        scrollEnabled={true}
        originWhitelist={["*"]}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#0f0f1a" },
  header: {
    padding: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
  },
  filename: {
    color: "#e0e0e0",
    fontSize: 14,
    fontFamily: "monospace",
  },
  webview: {
    flex: 1,
    backgroundColor: "#0f0f1a",
  },
});
