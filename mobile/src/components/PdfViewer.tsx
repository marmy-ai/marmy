import React, { useState } from "react";
import {
  View,
  Text,
  ActivityIndicator,
  StyleSheet,
} from "react-native";
import { WebView } from "react-native-webview";
import { theme } from "../theme";

interface PdfViewerProps {
  uri: string;
  headers: Record<string, string>;
  filename: string;
}

export default function PdfViewer({ uri, headers, filename }: PdfViewerProps) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.filename} numberOfLines={1}>
          {filename}
        </Text>
      </View>

      <View style={styles.content}>
        {loading && !error && (
          <ActivityIndicator
            size="large"
            color={theme.primary}
            style={styles.spinner}
          />
        )}

        {error ? (
          <Text style={styles.errorText}>Failed to load PDF</Text>
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
            javaScriptEnabled={false}
            scrollEnabled={true}
          />
        )}
      </View>
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
    backgroundColor: "#0f0f1a",
  },
  errorText: {
    color: "#ff6b6b",
    fontSize: 16,
    textAlign: "center",
    marginTop: 48,
  },
});
