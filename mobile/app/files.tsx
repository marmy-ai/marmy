import React, { useState, useCallback, useEffect } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  FlatList,
  StyleSheet,
  ActivityIndicator,
  Alert,
} from "react-native";
import { useLocalSearchParams, useRouter } from "expo-router";
import { useConnectionStore } from "../src/stores/connectionStore";
import { theme } from "../src/theme";
import FileTree from "../src/components/FileTree";
import CodeViewer from "../src/components/CodeViewer";
import ImageViewer, { isImageFile } from "../src/components/ImageViewer";
import MarkdownViewer from "../src/components/MarkdownViewer";
import PdfViewer from "../src/components/PdfViewer";
import type { DirEntry, SessionRoot } from "../src/types";

type Phase =
  | { kind: "roots"; sessionId: string; sessionName: string }
  | { kind: "browse"; sessionId: string }
  | { kind: "file"; path: string; content: string }
  | { kind: "image"; path: string }
  | { kind: "markdown"; path: string; content: string }
  | { kind: "pdf"; path: string };

export default function FilesScreen() {
  const { sessionId, sessionName } = useLocalSearchParams<{ sessionId: string; sessionName: string }>();
  const router = useRouter();
  const { api, connected, activeMachine } = useConnectionStore();
  const [phase, setPhase] = useState<Phase>({ kind: "roots", sessionId: sessionId || "", sessionName: sessionName || "" });
  const [roots, setRoots] = useState<SessionRoot[]>([]);
  const [currentPath, setCurrentPath] = useState("");
  const [entries, setEntries] = useState<DirEntry[]>([]);
  const [loading, setLoading] = useState(false);

  // Auto-load session roots on mount
  useEffect(() => {
    if (!api || !sessionId) return;
    setLoading(true);
    api.getSessionRoots(sessionId).then(async (sessionRoots) => {
      if (sessionRoots.length === 1) {
        const listing = await api.listDir(sessionRoots[0].path);
        setEntries(listing.entries);
        setCurrentPath(listing.path);
        setRoots(sessionRoots);
        setPhase({ kind: "browse", sessionId });
      } else {
        setRoots(sessionRoots);
        setPhase({ kind: "roots", sessionId, sessionName: sessionName || "" });
      }
    }).catch((e: any) => {
      Alert.alert("Error", e.message);
    }).finally(() => {
      setLoading(false);
    });
  }, [api, sessionId]);

  const loadDirectory = useCallback(
    async (path: string) => {
      if (!api) return;
      setLoading(true);
      try {
        const listing = await api.listDir(path);
        setEntries(listing.entries);
        setCurrentPath(listing.path);
      } catch (e: any) {
        Alert.alert("Error", e.message);
      } finally {
        setLoading(false);
      }
    },
    [api]
  );

  const selectRoot = useCallback(
    async (root: SessionRoot) => {
      if (!api) return;
      setLoading(true);
      try {
        const listing = await api.listDir(root.path);
        setEntries(listing.entries);
        setCurrentPath(listing.path);
        setPhase((prev) =>
          prev.kind === "roots"
            ? { kind: "browse", sessionId: prev.sessionId }
            : prev
        );
      } catch (e: any) {
        Alert.alert("Error", e.message);
      } finally {
        setLoading(false);
      }
    },
    [api]
  );

  const selectFile = useCallback(
    async (path: string) => {
      if (!api) return;
      const filename = path.split("/").pop() || path;

      if (isImageFile(filename)) {
        setPhase({ kind: "image", path });
        return;
      }

      if (isPdfFile(filename)) {
        setPhase({ kind: "pdf", path });
        return;
      }

      setLoading(true);
      try {
        const file = await api.readFile(path);
        if (isMarkdownFile(filename)) {
          setPhase({ kind: "markdown", path: file.path, content: file.content });
        } else {
          setPhase({ kind: "file", path: file.path, content: file.content });
        }
      } catch (e: any) {
        Alert.alert("Error", e.message);
      } finally {
        setLoading(false);
      }
    },
    [api]
  );

  const goBack = useCallback(() => {
    switch (phase.kind) {
      case "roots":
        router.back();
        break;
      case "browse":
        if (roots.length > 1) {
          setPhase({ kind: "roots", sessionId: phase.sessionId, sessionName: sessionName || "" });
        } else {
          router.back();
        }
        break;
      case "file":
      case "image":
      case "markdown":
      case "pdf":
        // Go back to browse — entries/currentPath are still in state
        setPhase({ kind: "browse", sessionId: sessionId || "" });
        break;
    }
  }, [phase, roots.length, router, sessionId, sessionName]);

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
        <ActivityIndicator size="large" color={theme.primary} />
      </View>
    );
  }

  // Phase: Image viewer
  if (phase.kind === "image") {
    const filename = phase.path.split("/").pop() || phase.path;
    return (
      <View style={styles.container}>
        <TouchableOpacity style={styles.backBtn} onPress={goBack}>
          <Text style={styles.backBtnText}>Back to files</Text>
        </TouchableOpacity>
        <ImageViewer
          uri={api!.getRawFileUrl(phase.path)}
          headers={api!.getAuthHeaders()}
          filename={filename}
        />
      </View>
    );
  }

  // Phase: Markdown viewer
  if (phase.kind === "markdown") {
    const filename = phase.path.split("/").pop() || phase.path;
    return (
      <View style={styles.container}>
        <TouchableOpacity style={styles.backBtn} onPress={goBack}>
          <Text style={styles.backBtnText}>Back to files</Text>
        </TouchableOpacity>
        <MarkdownViewer content={phase.content} filename={filename} />
      </View>
    );
  }

  // Phase: PDF viewer
  if (phase.kind === "pdf") {
    const filename = phase.path.split("/").pop() || phase.path;
    return (
      <View style={styles.container}>
        <TouchableOpacity style={styles.backBtn} onPress={goBack}>
          <Text style={styles.backBtnText}>Back to files</Text>
        </TouchableOpacity>
        <PdfViewer
          uri={api!.getRawFileUrl(phase.path)}
          headers={api!.getAuthHeaders()}
          filename={filename}
        />
      </View>
    );
  }

  // Phase: Text file viewer
  if (phase.kind === "file") {
    const filename = phase.path.split("/").pop() || phase.path;
    return (
      <View style={styles.container}>
        <TouchableOpacity style={styles.backBtn} onPress={goBack}>
          <Text style={styles.backBtnText}>Back to files</Text>
        </TouchableOpacity>
        <CodeViewer content={phase.content} filename={filename} />
      </View>
    );
  }

  // Phase: Directory browser
  if (phase.kind === "browse") {
    return (
      <View style={styles.container}>
        {roots.length > 1 && (
          <TouchableOpacity style={styles.backBtn} onPress={goBack}>
            <Text style={styles.backBtnText}>Back to roots</Text>
          </TouchableOpacity>
        )}
        <FileTree
          entries={entries}
          currentPath={currentPath}
          onNavigate={loadDirectory}
          onFileSelect={selectFile}
        />
      </View>
    );
  }

  // Phase: Root picker (multiple working directories)
  return (
    <View style={styles.container}>
      <View style={styles.listHeader}>
        <Text style={styles.listTitle}>Working Directories</Text>
      </View>
      <FlatList
        data={roots}
        keyExtractor={(item) => item.pane_id}
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.entry}
            onPress={() => selectRoot(item)}
          >
            <View style={styles.entryContent}>
              <Text style={styles.entryTitle} numberOfLines={1}>
                {item.path}
              </Text>
              <Text style={styles.entrySubtitle} numberOfLines={1}>
                {item.window_name} — {item.current_command}
              </Text>
            </View>
          </TouchableOpacity>
        )}
        ListEmptyComponent={
          <View style={styles.center}>
            <Text style={styles.emptyText}>No working directories found</Text>
          </View>
        }
      />
    </View>
  );
}

function isMarkdownFile(name: string): boolean {
  return /\.(md|mdx)$/i.test(name);
}

function isPdfFile(name: string): boolean {
  return /\.pdf$/i.test(name);
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: theme.bgDeep },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: theme.bgDeep,
    padding: 32,
  },
  emptyText: { color: theme.textSecondary, fontSize: 18 },
  backBtn: {
    paddingVertical: 14,
    paddingHorizontal: 16,
    borderBottomWidth: 1,
    borderBottomColor: theme.border,
    backgroundColor: theme.bgCard,
    zIndex: 10,
    minHeight: 48,
    justifyContent: "center",
  },
  backBtnText: { color: theme.primary, fontSize: 15 },
  listHeader: {
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: theme.border,
    backgroundColor: theme.bgCard,
  },
  listTitle: {
    color: theme.textPrimary,
    fontSize: 18,
    fontWeight: "600",
  },
  entry: {
    paddingVertical: 14,
    paddingHorizontal: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: theme.bgCard,
  },
  entryContent: {
    gap: 4,
  },
  entryTitle: {
    color: theme.textPrimary,
    fontSize: 16,
  },
  entrySubtitle: {
    color: theme.textSecondary,
    fontSize: 13,
  },
});
