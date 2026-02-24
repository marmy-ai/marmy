import React from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
} from "react-native";
import type { DirEntry } from "../types";

interface FileTreeProps {
  entries: DirEntry[];
  currentPath: string;
  onNavigate: (path: string) => void;
  onFileSelect: (path: string) => void;
}

export default function FileTree({
  entries,
  currentPath,
  onNavigate,
  onFileSelect,
}: FileTreeProps) {
  const parentPath = currentPath.split("/").slice(0, -1).join("/") || "/";

  return (
    <View style={styles.container}>
      <View style={styles.breadcrumb}>
        <Text style={styles.breadcrumbText} numberOfLines={1}>
          {currentPath}
        </Text>
      </View>

      <FlatList
        data={entries}
        keyExtractor={(item) => item.path}
        ListHeaderComponent={
          currentPath !== "/" ? (
            <TouchableOpacity
              style={styles.entry}
              onPress={() => onNavigate(parentPath)}
            >
              <Text style={styles.dirIcon}>..</Text>
              <Text style={styles.dirName}>Parent directory</Text>
            </TouchableOpacity>
          ) : null
        }
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.entry}
            onPress={() =>
              item.is_dir ? onNavigate(item.path) : onFileSelect(item.path)
            }
          >
            <Text style={item.is_dir ? styles.dirIcon : styles.fileIcon}>
              {item.is_dir ? "D" : "F"}
            </Text>
            <Text
              style={item.is_dir ? styles.dirName : styles.fileName}
              numberOfLines={1}
            >
              {item.name}
            </Text>
            {!item.is_dir && (
              <Text style={styles.fileSize}>{formatSize(item.size)}</Text>
            )}
          </TouchableOpacity>
        )}
      />
    </View>
  );
}

function formatSize(bytes: number): string {
  if (bytes < 1024) return `${bytes}B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)}K`;
  return `${(bytes / (1024 * 1024)).toFixed(1)}M`;
}

const styles = StyleSheet.create({
  container: { flex: 1 },
  breadcrumb: {
    padding: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
  },
  breadcrumbText: { color: "#888", fontSize: 12, fontFamily: "monospace" },
  entry: {
    flexDirection: "row",
    alignItems: "center",
    paddingVertical: 10,
    paddingHorizontal: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#1a1a2e",
  },
  dirIcon: {
    color: "#7c3aed",
    fontSize: 14,
    fontWeight: "700",
    width: 24,
    fontFamily: "monospace",
  },
  fileIcon: {
    color: "#555",
    fontSize: 14,
    width: 24,
    fontFamily: "monospace",
  },
  dirName: { color: "#7c3aed", fontSize: 15, flex: 1 },
  fileName: { color: "#d0d0d0", fontSize: 15, flex: 1 },
  fileSize: { color: "#555", fontSize: 12, fontFamily: "monospace" },
});
