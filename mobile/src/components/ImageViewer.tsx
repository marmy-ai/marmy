import React, { useState } from "react";
import {
  View,
  Image,
  Text,
  ActivityIndicator,
  StyleSheet,
} from "react-native";
import { theme } from "../theme";

interface ImageViewerProps {
  uri: string;
  headers: Record<string, string>;
  filename: string;
}

const IMAGE_EXTENSIONS = new Set([
  "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico",
]);

/** Check if a filename has an image extension. */
export function isImageFile(filename: string): boolean {
  const ext = filename.split(".").pop()?.toLowerCase() ?? "";
  return IMAGE_EXTENSIONS.has(ext);
}

export default function ImageViewer({ uri, headers, filename }: ImageViewerProps) {
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState(false);

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Text style={styles.filename} numberOfLines={1}>
          {filename}
        </Text>
      </View>

      <View style={styles.imageContainer}>
        {loading && !error && (
          <ActivityIndicator
            size="large"
            color={theme.primary}
            style={styles.spinner}
          />
        )}

        {error ? (
          <Text style={styles.errorText}>Failed to load image</Text>
        ) : (
          <Image
            source={{ uri, headers }}
            style={styles.image}
            resizeMode="contain"
            onLoadStart={() => setLoading(true)}
            onLoadEnd={() => setLoading(false)}
            onError={() => {
              setLoading(false);
              setError(true);
            }}
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
  imageContainer: {
    flex: 1,
    justifyContent: "center",
    alignItems: "center",
  },
  spinner: {
    position: "absolute",
  },
  image: {
    width: "100%",
    height: "100%",
  },
  errorText: {
    color: "#ff6b6b",
    fontSize: 16,
  },
});
