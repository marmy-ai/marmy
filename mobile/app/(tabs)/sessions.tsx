import React from "react";
import {
  View,
  Text,
  SectionList,
  TouchableOpacity,
  StyleSheet,
} from "react-native";
import { useRouter } from "expo-router";
import { useConnectionStore } from "../../src/stores/connectionStore";
import { useSessionStore } from "../../src/stores/sessionStore";
import type { TmuxPane, TmuxWindow, TmuxSession } from "../../src/types";

export default function SessionsScreen() {
  const { topology, activeMachine, connected } = useConnectionStore();
  const { setActivePane, setActiveSession } = useSessionStore();
  const router = useRouter();

  if (!connected || !activeMachine) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyText}>Not connected to any machine.</Text>
        <Text style={styles.emptySubtext}>
          Go to the Machines tab and connect first.
        </Text>
      </View>
    );
  }

  if (!topology || topology.sessions.length === 0) {
    return (
      <View style={styles.center}>
        <Text style={styles.emptyText}>No tmux sessions found.</Text>
        <Text style={styles.emptySubtext}>
          Start a tmux session on {activeMachine.name} first.
        </Text>
      </View>
    );
  }

  // Build sections: one per session, items are panes grouped by window
  const sections = topology.sessions.map((session) => {
    const sessionWindows = topology.windows.filter(
      (w) => w.session_id === session.id
    );
    const panes: (TmuxPane & { windowName: string })[] = [];

    for (const win of sessionWindows) {
      const windowPanes = topology.panes.filter(
        (p) => p.window_id === win.id
      );
      for (const pane of windowPanes) {
        panes.push({ ...pane, windowName: win.name });
      }
    }

    return {
      title: session.name,
      session,
      data: panes,
    };
  });

  const handlePanePress = (pane: TmuxPane) => {
    setActivePane(pane.id);
    setActiveSession(pane.session_id);
    router.push("/(tabs)/terminal");
  };

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <View style={[styles.statusDot, { backgroundColor: "#22c55e" }]} />
        <Text style={styles.headerText}>{activeMachine.name}</Text>
      </View>

      <SectionList
        sections={sections}
        keyExtractor={(item) => item.id}
        renderSectionHeader={({ section }) => (
          <View style={styles.sectionHeader}>
            <Text style={styles.sectionTitle}>{section.title}</Text>
            <Text style={styles.sectionBadge}>
              {section.session.attached ? "attached" : "detached"}
            </Text>
          </View>
        )}
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.paneCard}
            onPress={() => handlePanePress(item)}
          >
            <View style={styles.paneHeader}>
              <Text style={styles.paneName}>
                {item.windowName}:{item.index}
              </Text>
              {item.active && <View style={styles.activeDot} />}
            </View>
            <Text style={styles.paneCommand}>{item.current_command}</Text>
            <Text style={styles.panePath} numberOfLines={1}>
              {item.current_path}
            </Text>
            <Text style={styles.paneDimensions}>
              {item.width}x{item.height}
            </Text>
          </TouchableOpacity>
        )}
        contentContainerStyle={styles.list}
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#0f0f1a" },
  center: { flex: 1, alignItems: "center", justifyContent: "center", backgroundColor: "#0f0f1a" },
  emptyText: { color: "#888", fontSize: 18, marginBottom: 8 },
  emptySubtext: { color: "#555", fontSize: 14 },
  header: {
    flexDirection: "row",
    alignItems: "center",
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: "#2a2a3e",
  },
  statusDot: { width: 8, height: 8, borderRadius: 4, marginRight: 8 },
  headerText: { color: "#e0e0e0", fontSize: 16, fontWeight: "600" },
  list: { padding: 16 },
  sectionHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingVertical: 8,
    marginTop: 8,
  },
  sectionTitle: { color: "#7c3aed", fontSize: 16, fontWeight: "700" },
  sectionBadge: {
    color: "#888",
    fontSize: 12,
    backgroundColor: "#1a1a2e",
    paddingHorizontal: 8,
    paddingVertical: 2,
    borderRadius: 4,
  },
  paneCard: {
    backgroundColor: "#1a1a2e",
    borderRadius: 10,
    padding: 14,
    marginBottom: 8,
    borderWidth: 1,
    borderColor: "#2a2a3e",
  },
  paneHeader: { flexDirection: "row", alignItems: "center", marginBottom: 4 },
  paneName: { color: "#e0e0e0", fontSize: 16, fontWeight: "500" },
  activeDot: {
    width: 6,
    height: 6,
    borderRadius: 3,
    backgroundColor: "#22c55e",
    marginLeft: 8,
  },
  paneCommand: { color: "#7c3aed", fontSize: 14, marginBottom: 2 },
  panePath: { color: "#666", fontSize: 12, marginBottom: 2 },
  paneDimensions: { color: "#555", fontSize: 11 },
});
