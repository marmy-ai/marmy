import React, { useState, useEffect, useCallback } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  Alert,
} from "react-native";
import { useConnectionStore } from "../../src/stores/connectionStore";
import FileTree from "../../src/components/FileTree";
import CodeViewer from "../../src/components/CodeViewer";
import type { DirEntry } from "../../src/types";

export default function FilesScreen() {
  const { api, connected, activeMachine } = useConnectionStore();
  const [roots, setRoots] = useState<string[]>([]);
  const [currentPath, setCurrentPath] = useState("");
  const [entries, setEntries] = useState<DirEntry[]>([]);
  const [loading, setLoading] = useState(false);
  const [selectedFile, setSelectedFile] = useState<{
    path: string;
    content: string;
  } | null>(null);

  const loadDirectory = useCallback(
    async (path: string) => {
      if (!api) return;
      setLoading(true);
      try {
        const listing = await api.listDir(path);
        setEntries(listing.entries);
        setCurrentPath(listing.path);
        setSelectedFile(null);
      } catch (e: any) {
        Alert.alert("Error", e.message);
      } finally {
        setLoading(false);
      }
    },
    [api]
  );

  const loadFile = useCallback(
    async (path: string) => {
      if (!api) return;
      setLoading(true);
      try {
        const file = await api.readFile(path);
        setSelectedFile({ path: file.path, content: file.content });
      } catch (e: any) {
        Alert.alert("Error", e.message);
      } finally {
        setLoading(false);
      }
    },
    [api]
  );

  // Fetch allowed roots, then load the first one
  useEffect(() => {
    if (connected && api) {
      api.getFileRoots().then((r) => {
        setRoots(r);
        if (r.length > 0) {
          loadDirectory(r[0]);
        }
      }).catch((e: any) => Alert.alert("Error", e.message));
    }
  }, [connected, api, loadDirectory]);

  if (!connected || !activeMachine) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyText}>Not connected.</Text>
      </View>
    );
  }

  if (loading) {
    return (
      <View style={styles.center}>
        <ActivityIndicator size="large" color="#7c3aed" />
      </View>
    );
  }

  // Show file content
  if (selectedFile) {
    const filename = selectedFile.path.split("/").pop() || selectedFile.path;
    return (
      <View style={styles.container}>
        <TouchableOpacity
          style={styles.backBtn}
          onPress={() => setSelectedFile(null)}
        >
          <Text style={styles.backBtnText}>Back to files</Text>
        </TouchableOpacity>
        <CodeViewer content={selectedFile.content} filename={filename} />
      </View>
    );
  }

  // Show directory listing
  return (
    <View style={styles.container}>
      <FileTree
        entries={entries}
        currentPath={currentPath}
        onNavigate={loadDirectory}
        onFileSelect={loadFile}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#0f0f1a" },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: "#0f0f1a",
  },
  emptyText: { color: "#888", fontSize: 18 },
  backBtn: {
    padding: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
  },
  backBtnText: { color: "#7c3aed", fontSize: 15 },
});
