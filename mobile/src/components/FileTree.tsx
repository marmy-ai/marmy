import React from "react";
import {
  View,
  Text,
  FlatList,
  TouchableOpacity,
  StyleSheet,
} from "react-native";
import { Ionicons } from "@expo/vector-icons";
import { theme } from "../theme";
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
              accessibilityRole="button"
              accessibilityLabel="Go to parent directory"
            >
              <Ionicons
                name="arrow-up-outline"
                size={16}
                color={theme.primary}
                style={styles.entryIcon}
              />
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
            accessibilityRole="button"
            accessibilityLabel={`${item.is_dir ? "Folder" : "File"}: ${item.name}`}
          >
            <Ionicons
              name={item.is_dir ? "folder-outline" : "document-text-outline"}
              size={16}
              color={item.is_dir ? theme.primary : theme.textTertiary}
              style={styles.entryIcon}
            />
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
    borderBottomColor: theme.border,
    backgroundColor: theme.bgCard,
  },
  breadcrumbText: { color: theme.textSecondary, fontSize: 12, fontFamily: "monospace" },
  entry: {
    flexDirection: "row",
    alignItems: "center",
    paddingVertical: 10,
    paddingHorizontal: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.bgCard,
  },
  entryIcon: { width: 24 },
  dirName: { color: theme.primary, fontSize: 15, flex: 1 },
  fileName: { color: theme.textPrimary, fontSize: 15, flex: 1 },
  fileSize: { color: theme.textTertiary, fontSize: 12, fontFamily: "monospace" },
});
