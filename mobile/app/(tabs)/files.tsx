import React, { useState, useCallback } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  FlatList,
  StyleSheet,
  ActivityIndicator,
  Alert,
} from "react-native";
import { useConnectionStore } from "../../src/stores/connectionStore";
import FileTree from "../../src/components/FileTree";
import CodeViewer from "../../src/components/CodeViewer";
import ImageViewer, { isImageFile } from "../../src/components/ImageViewer";
import MarkdownViewer from "../../src/components/MarkdownViewer";
import PdfViewer from "../../src/components/PdfViewer";
import type { DirEntry, SessionRoot, TmuxSession } from "../../src/types";

type Phase =
  | { kind: "sessions" }
  | { kind: "roots"; sessionId: string; sessionName: string }
  | { kind: "browse"; sessionId: string }
  | { kind: "file"; path: string; content: string }
  | { kind: "image"; path: string }
  | { kind: "markdown"; path: string; content: string }
  | { kind: "pdf"; path: string };

export default function FilesScreen() {
  const { api, connected, activeMachine, topology } = useConnectionStore();
  const [phase, setPhase] = useState<Phase>({ kind: "sessions" });
  const [roots, setRoots] = useState<SessionRoot[]>([]);
  const [currentPath, setCurrentPath] = useState("");
  const [entries, setEntries] = useState<DirEntry[]>([]);
  const [loading, setLoading] = useState(false);

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

  const selectSession = useCallback(
    async (session: TmuxSession) => {
      if (!api) return;
      setLoading(true);
      try {
        const sessionRoots = await api.getSessionRoots(session.id);
        if (sessionRoots.length === 1) {
          // Single root — skip root picker, go straight to browsing
          const listing = await api.listDir(sessionRoots[0].path);
          setEntries(listing.entries);
          setCurrentPath(listing.path);
          setRoots(sessionRoots);
          setPhase({ kind: "browse", sessionId: session.id });
        } else {
          setRoots(sessionRoots);
          setPhase({ kind: "roots", sessionId: session.id, sessionName: session.name });
        }
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
        setPhase({ kind: "sessions" });
        break;
      case "browse":
        if (roots.length > 1) {
          setPhase({ kind: "roots", sessionId: phase.sessionId, sessionName: "" });
        } else {
          setPhase({ kind: "sessions" });
        }
        break;
      case "file":
      case "image":
      case "markdown":
      case "pdf":
        // Go back to browse — entries/currentPath are still in state
        setPhase({ kind: "browse", sessionId: "" });
        break;
    }
  }, [phase, roots.length]);

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
        <TouchableOpacity style={styles.backBtn} onPress={goBack}>
          <Text style={styles.backBtnText}>Back to sessions</Text>
        </TouchableOpacity>
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
  if (phase.kind === "roots") {
    return (
      <View style={styles.container}>
        <TouchableOpacity style={styles.backBtn} onPress={goBack}>
          <Text style={styles.backBtnText}>Back to sessions</Text>
        </TouchableOpacity>
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

  // Phase: Session picker (default)
  const sessions = topology?.sessions ?? [];

  return (
    <View style={styles.container}>
      <View style={styles.listHeader}>
        <Text style={styles.listTitle}>Select Session</Text>
      </View>
      <FlatList
        data={sessions}
        keyExtractor={(item) => item.id}
        renderItem={({ item }) => {
          const windowCount = topology?.windows.filter(
            (w) => w.session_id === item.id
          ).length ?? 0;
          const paneCount = topology?.panes.filter(
            (p) => p.session_id === item.id
          ).length ?? 0;
          return (
            <TouchableOpacity
              style={styles.entry}
              onPress={() => selectSession(item)}
            >
              <View style={styles.entryContent}>
                <Text style={styles.entryTitle}>{item.name}</Text>
                <Text style={styles.entrySubtitle}>
                  {windowCount} window{windowCount !== 1 ? "s" : ""},{" "}
                  {paneCount} pane{paneCount !== 1 ? "s" : ""}
                </Text>
              </View>
            </TouchableOpacity>
          );
        }}
        ListEmptyComponent={
          <View style={styles.center}>
            <Text style={styles.emptyText}>No sessions found</Text>
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
  container: { flex: 1, backgroundColor: "#0f0f1a" },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: "#0f0f1a",
    padding: 32,
  },
  emptyText: { color: "#888", fontSize: 18 },
  backBtn: {
    padding: 12,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
  },
  backBtnText: { color: "#7c3aed", fontSize: 15 },
  listHeader: {
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
  },
  listTitle: {
    color: "#e0e0e0",
    fontSize: 18,
    fontWeight: "600",
  },
  entry: {
    paddingVertical: 14,
    paddingHorizontal: 16,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: "#1a1a2e",
  },
  entryContent: {
    gap: 4,
  },
  entryTitle: {
    color: "#e0e0e0",
    fontSize: 16,
  },
  entrySubtitle: {
    color: "#888",
    fontSize: 13,
  },
});
