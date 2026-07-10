import React, { useState } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  ActivityIndicator,
  Linking,
  StyleSheet,
} from "react-native";
import { WebView } from "react-native-webview";
import { theme } from "../theme";
import CodeViewer from "./CodeViewer";

interface HtmlViewerProps {
  uri: string;
  headers: Record<string, string>;
  filename: string;
  /** Lazily fetches the file's text for the Source tab. */
  loadSource: () => Promise<string>;
}

// Renders agent-generated HTML (reports, dashboards, artifacts) in a WebView
// with JS enabled, so interactive pages work. Self-contained pages render
// fully; relative assets (./style.css) won't load because the agent serves
// files via /api/files/raw?path=... and subresource requests carry neither
// the query path nor the auth header. A Source tab shows the raw markup.
export default function HtmlViewer({
  uri,
  headers,
  filename,
  loadSource,
}: HtmlViewerProps) {
  const [mode, setMode] = useState<"preview" | "source">("preview");
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);
  const [source, setSource] = useState<string | null>(null);
  const [sourceError, setSourceError] = useState<string | null>(null);

  const showSource = async () => {
    setMode("source");
    if (source !== null) return;
    try {
      setSource(await loadSource());
    } catch (e: any) {
      setSourceError(e?.message ?? String(e));
    }
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.filename} numberOfLines={1}>
          {filename}
        </Text>
        <View style={styles.toggle}>
          <TouchableOpacity
            style={[
              styles.segment,
              styles.segmentLeft,
              mode === "preview" && styles.segmentActive,
            ]}
            onPress={() => setMode("preview")}
            accessibilityRole="button"
            accessibilityLabel="Rendered preview"
          >
            <Text
              style={[
                styles.segmentText,
                mode === "preview" && styles.segmentTextActive,
              ]}
            >
              Preview
            </Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[
              styles.segment,
              styles.segmentRight,
              mode === "source" && styles.segmentActive,
            ]}
            onPress={showSource}
            accessibilityRole="button"
            accessibilityLabel="View source"
          >
            <Text
              style={[
                styles.segmentText,
                mode === "source" && styles.segmentTextActive,
              ]}
            >
              Source
            </Text>
          </TouchableOpacity>
        </View>
      </View>

      {mode === "source" ? (
        sourceError ? (
          <Text style={styles.errorText}>{sourceError}</Text>
        ) : source === null ? (
          <ActivityIndicator
            size="large"
            color={theme.primary}
            style={styles.spinner}
          />
        ) : (
          <CodeViewer content={source} filename={filename} />
        )
      ) : (
        <View style={styles.content}>
          {loading && !error && (
            <ActivityIndicator
              size="large"
              color={theme.primary}
              style={styles.spinner}
            />
          )}

          {error ? (
            <Text style={styles.errorText}>Failed to load page</Text>
          ) : (
            <WebView
              source={{ uri, headers }}
              style={styles.webview}
              onLoadEnd={() => setLoading(false)}
              onError={() => {
                setLoading(false);
                setError(true);
              }}
              originWhitelist={["*"]}
              javaScriptEnabled
              setSupportMultipleWindows={false}
              onShouldStartLoadWithRequest={(request) => {
                // The page itself (and in-page anchors) load in the WebView;
                // links out of the document open in the system browser.
                if (
                  request.url === uri ||
                  request.url.startsWith(`${uri}#`) ||
                  request.url.startsWith("about:")
                ) {
                  return true;
                }
                if (/^https?:\/\//.test(request.url)) {
                  Linking.openURL(request.url).catch(() => {});
                }
                return false;
              }}
              scrollEnabled
            />
          )}
        </View>
      )}
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: theme.bgDeep },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    gap: 12,
    padding: 12,
    borderBottomWidth: 1,
    borderBottomColor: theme.border,
    backgroundColor: theme.bgCard,
  },
  filename: {
    flex: 1,
    color: theme.textPrimary,
    fontSize: 14,
    fontFamily: "monospace",
  },
  toggle: {
    flexDirection: "row",
    borderRadius: 8,
    overflow: "hidden",
  },
  segment: {
    paddingHorizontal: 12,
    paddingVertical: 6,
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
    fontWeight: "600",
  },
  segmentTextActive: {
    color: "#fff",
  },
  content: {
    flex: 1,
  },
  spinner: {
    position: "absolute",
    alignSelf: "center",
    top: "50%",
    zIndex: 1,
  },
  webview: {
    flex: 1,
    // White, not bgDeep: pages rarely set an explicit background and expect
    // the browser default; dark would make unstyled text unreadable.
    backgroundColor: "#ffffff",
  },
  errorText: {
    color: theme.error,
    fontSize: 16,
    textAlign: "center",
    marginTop: 48,
  },
});
