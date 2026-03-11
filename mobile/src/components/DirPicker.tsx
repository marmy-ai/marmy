import React, { useState, useEffect, useCallback } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  ActivityIndicator,
  StyleSheet,
} from "react-native";
import Constants from "expo-constants";
import type { MarmyApi } from "../services/api";
import { theme } from "../theme";
import type { DirEntry } from "../types";

interface DirPickerProps {
  api: MarmyApi;
  recentDirs: string[];
  onSelect: (path: string) => void;
  onCancel: () => void;
}

export default function DirPicker({ api, recentDirs, onSelect, onCancel }: DirPickerProps) {
  const [currentPath, setCurrentPath] = useState("/");
  const [entries, setEntries] = useState<DirEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [browsing, setBrowsing] = useState(false);

  const loadDir = useCallback(async (path: string) => {
    setLoading(true);
    setError(null);
    try {
      const listing = await api.listDir(path);
      const dirs = listing.entries.filter((e) => e.is_dir).sort((a, b) => a.name.localeCompare(b.name));
      setEntries(dirs);
      setCurrentPath(listing.path);
    } catch (e: any) {
      setError(e.message);
    } finally {
      setLoading(false);
    }
  }, [api]);

  useEffect(() => {
    if (browsing) {
      loadDir(currentPath);
    }
  }, [browsing]);

  const navigateTo = (path: string) => {
    setCurrentPath(path);
    loadDir(path);
  };

  const shortName = (fullPath: string) => {
    const parts = fullPath.split("/").filter(Boolean);
    return parts[parts.length - 1] || "/";
  };

  const breadcrumbSegments = () => {
    const parts = currentPath.split("/").filter(Boolean);
    const segments: { label: string; path: string }[] = [{ label: "/", path: "/" }];
    let accumulated = "";
    for (const part of parts) {
      accumulated += "/" + part;
      segments.push({ label: part, path: accumulated });
    }
    return segments;
  };

  // Quick picks view
  if (!browsing) {
    return (
      <View style={styles.container}>
        <View style={styles.header}>
          <TouchableOpacity onPress={onCancel} hitSlop={{ top: 16, bottom: 16, left: 16, right: 16 }}>
            <Text style={styles.cancelText}>Cancel</Text>
          </TouchableOpacity>
          <Text style={styles.title}>Select Directory</Text>
          <View style={{ width: 60 }} />
        </View>

        <ScrollView contentContainerStyle={styles.content}>
          {recentDirs.length > 0 && (
            <>
              <Text style={styles.sectionLabel}>Recent Projects</Text>
              <View style={styles.pillsContainer}>
                {recentDirs.map((dir) => (
                  <TouchableOpacity
                    key={dir}
                    style={styles.quickPick}
                    onPress={() => onSelect(dir)}
                  >
                    <Text style={styles.quickPickIcon}>📁</Text>
                    <View style={styles.quickPickText}>
                      <Text style={styles.quickPickName} numberOfLines={1}>
                        {shortName(dir)}
                      </Text>
                      <Text style={styles.quickPickPath} numberOfLines={1}>
                        {dir}
                      </Text>
                    </View>
                  </TouchableOpacity>
                ))}
              </View>
            </>
          )}

          <Text style={[styles.sectionLabel, { marginTop: 20 }]}>Or browse</Text>
          <TouchableOpacity
            style={styles.browseBtn}
            onPress={() => setBrowsing(true)}
          >
            <Text style={styles.browseBtnText}>Browse filesystem...</Text>
          </TouchableOpacity>
        </ScrollView>
      </View>
    );
  }

  // Browse view
  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <TouchableOpacity onPress={() => setBrowsing(false)} hitSlop={{ top: 16, bottom: 16, left: 16, right: 16 }}>
          <Text style={styles.cancelText}>Back</Text>
        </TouchableOpacity>
        <Text style={styles.title}>Browse</Text>
        <View style={{ width: 60 }} />
      </View>

      {/* Breadcrumb */}
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={styles.breadcrumbBar}>
        {breadcrumbSegments().map((seg, i) => (
          <TouchableOpacity key={seg.path} onPress={() => navigateTo(seg.path)}>
            <Text style={styles.breadcrumbText}>
              {i > 0 ? " / " : ""}
              {seg.label}
            </Text>
          </TouchableOpacity>
        ))}
      </ScrollView>

      {/* Directory listing */}
      <ScrollView style={styles.listArea}>
        {loading && (
          <ActivityIndicator color={theme.primary} style={{ marginTop: 20 }} />
        )}
        {error && <Text style={styles.errorText}>{error}</Text>}
        {!loading && !error && (
          <>
            {currentPath !== "/" && (
              <TouchableOpacity
                style={styles.dirRow}
                onPress={() => {
                  const parent = currentPath.replace(/\/[^/]+\/?$/, "") || "/";
                  navigateTo(parent);
                }}
              >
                <Text style={styles.dirIcon}>📂</Text>
                <Text style={styles.dirName}>..</Text>
              </TouchableOpacity>
            )}
            {entries.map((entry) => (
              <TouchableOpacity
                key={entry.path}
                style={styles.dirRow}
                onPress={() => navigateTo(entry.path)}
              >
                <Text style={styles.dirIcon}>📁</Text>
                <Text style={styles.dirName} numberOfLines={1}>
                  {entry.name}
                </Text>
              </TouchableOpacity>
            ))}
            {!loading && entries.length === 0 && currentPath !== "/" && (
              <Text style={styles.emptyText}>No subdirectories</Text>
            )}
          </>
        )}
      </ScrollView>

      {/* Sticky select button */}
      <View style={styles.selectBar}>
        <TouchableOpacity
          style={styles.selectBtn}
          onPress={() => onSelect(currentPath)}
        >
          <Text style={styles.selectBtnText}>Select this folder</Text>
          <Text style={styles.selectBtnPath} numberOfLines={1}>
            {currentPath}
          </Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: "#0f0f1a",
    paddingTop: Constants.statusBarHeight,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    paddingVertical: 14,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
  },
  cancelText: { color: theme.primary, fontSize: 15 },
  title: { color: "#e0e0e0", fontSize: 17, fontWeight: "600" },
  content: { padding: 16 },
  sectionLabel: {
    color: "#888",
    fontSize: 13,
    fontWeight: "600",
    textTransform: "uppercase",
    letterSpacing: 0.5,
    marginBottom: 10,
  },
  pillsContainer: { gap: 8 },
  quickPick: {
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: "#1a1a2e",
    borderRadius: 10,
    padding: 12,
    borderWidth: 1,
    borderColor: "#2a2a3e",
  },
  quickPickIcon: { fontSize: 20, marginRight: 10 },
  quickPickText: { flex: 1 },
  quickPickName: { color: "#e0e0e0", fontSize: 15, fontWeight: "600" },
  quickPickPath: { color: "#666", fontSize: 12, marginTop: 2 },
  browseBtn: {
    backgroundColor: "#1a1a2e",
    borderRadius: 10,
    padding: 14,
    alignItems: "center",
    borderWidth: 1,
    borderColor: "#2a2a3e",
  },
  browseBtnText: { color: theme.primary, fontSize: 15, fontWeight: "500" },
  breadcrumbBar: {
    paddingHorizontal: 16,
    paddingVertical: 10,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
    maxHeight: 44,
  },
  breadcrumbText: { color: theme.primary, fontSize: 14 },
  listArea: { flex: 1 },
  dirRow: {
    flexDirection: "row",
    alignItems: "center",
    paddingHorizontal: 16,
    paddingVertical: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#1a1a2e",
  },
  dirIcon: { fontSize: 18, marginRight: 10 },
  dirName: { color: "#e0e0e0", fontSize: 15, flex: 1 },
  emptyText: { color: "#555", fontSize: 14, textAlign: "center", marginTop: 20 },
  errorText: { color: "#ef4444", fontSize: 14, textAlign: "center", marginTop: 20, paddingHorizontal: 16 },
  selectBar: {
    padding: 16,
    borderTopWidth: 1,
    borderTopColor: "#2a2a3e",
  },
  selectBtn: {
    backgroundColor: theme.primary,
    borderRadius: 10,
    paddingVertical: 14,
    paddingHorizontal: 16,
    alignItems: "center",
  },
  selectBtnText: { color: "#fff", fontSize: 16, fontWeight: "600" },
  selectBtnPath: { color: "rgba(255,255,255,0.6)", fontSize: 12, marginTop: 4 },
});
