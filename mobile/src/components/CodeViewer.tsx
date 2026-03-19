import React, { useState, useMemo } from "react";
import {
  View,
  Text,
  ScrollView,
  StyleSheet,
} from "react-native";
import { WebView } from "react-native-webview";

interface CodeViewerProps {
  content: string;
  filename: string;
  highlightLine?: number;
}

const EXT_TO_LANGUAGE: Record<string, string> = {
  js: "javascript", mjs: "javascript", cjs: "javascript", jsx: "javascript",
  ts: "typescript", tsx: "typescript",
  py: "python", rb: "ruby", rs: "rust", go: "go",
  java: "java", kt: "kotlin", kts: "kotlin", swift: "swift",
  c: "c", h: "c", cpp: "cpp", cc: "cpp", hpp: "cpp", cs: "csharp",
  css: "css", scss: "scss", less: "less",
  html: "xml", htm: "xml", xml: "xml", svg: "xml",
  json: "json", yaml: "yaml", yml: "yaml", toml: "ini",
  md: "markdown", mdx: "markdown",
  sh: "bash", bash: "bash", zsh: "bash", fish: "bash",
  sql: "sql", graphql: "graphql", gql: "graphql",
  dockerfile: "dockerfile", makefile: "makefile",
  lua: "lua", r: "r", php: "php", pl: "perl",
  ex: "elixir", exs: "elixir", erl: "erlang", hs: "haskell",
  clj: "clojure", scala: "scala", dart: "dart",
  vue: "xml", svelte: "xml",
};

function detectLanguage(filename: string): string | undefined {
  const base = filename.toLowerCase().split("/").pop() || "";
  if (base === "dockerfile") return "dockerfile";
  if (base === "makefile") return "makefile";
  const ext = base.split(".").pop();
  if (!ext || ext === base) return undefined;
  return EXT_TO_LANGUAGE[ext];
}

function escapeHtml(text: string): string {
  return text
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

function buildHtml(code: string, language: string | undefined): string {
  const escaped = escapeHtml(code);
  const langClass = language ? `language-${language}` : "";

  return `<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/atom-one-dark.min.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/highlight.min.js"></script>
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #0f0f1a;
    color: #d0d0d0;
    font-family: Menlo, 'Courier New', monospace;
    font-size: 13px;
    line-height: 20px;
    -webkit-text-size-adjust: none;
  }
  pre { padding: 8px; overflow-x: auto; }
  code.hljs {
    background: transparent !important;
    padding: 0 !important;
  }
  /* Line numbers */
  table { border-collapse: collapse; }
  td.line-num {
    color: #555;
    text-align: right;
    padding-right: 12px;
    user-select: none;
    -webkit-user-select: none;
    vertical-align: top;
    white-space: nowrap;
  }
  td.line-code {
    white-space: pre;
    padding-left: 4px;
  }
</style>
</head>
<body>
<pre><code id="code" class="${langClass}">${escaped}</code></pre>
<script>
  try {
    ${language ? 'hljs.highlightElement(document.getElementById("code"));' : ''}

    // Add line numbers after highlighting
    var code = document.getElementById("code");
    var lines = code.innerHTML.split("\\n");
    var table = document.createElement("table");
    for (var i = 0; i < lines.length; i++) {
      var tr = document.createElement("tr");
      var numTd = document.createElement("td");
      numTd.className = "line-num";
      numTd.textContent = (i + 1).toString();
      var codeTd = document.createElement("td");
      codeTd.className = "line-code";
      codeTd.innerHTML = lines[i] || " ";
      tr.appendChild(numTd);
      tr.appendChild(codeTd);
      table.appendChild(tr);
    }
    code.parentElement.replaceWith(table);
  } catch(e) {
    // highlight failed, plain text still visible
  }
</script>
</body>
</html>`;
}

export default function CodeViewer({
  content,
  filename,
  highlightLine,
}: CodeViewerProps) {
  const lines = content.split("\n");
  const language = detectLanguage(filename);
  const [webViewFailed, setWebViewFailed] = useState(false);

  const html = useMemo(() => buildHtml(content, language), [content, language]);

  // Use WebView with highlight.js for syntax highlighting
  if (!webViewFailed) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <Text style={styles.filename} numberOfLines={1}>
            {filename}
          </Text>
          <Text style={styles.lineCount}>{lines.length} lines</Text>
        </View>
        <WebView
          source={{ html }}
          style={styles.webview}
          originWhitelist={["*"]}
          scrollEnabled={true}
          showsVerticalScrollIndicator={true}
          showsHorizontalScrollIndicator={true}
          onError={() => setWebViewFailed(true)}
          onHttpError={() => setWebViewFailed(true)}
        />
      </View>
    );
  }

  // Fallback: plain text with line numbers
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
  webview: { flex: 1, backgroundColor: "#0f0f1a" },
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
