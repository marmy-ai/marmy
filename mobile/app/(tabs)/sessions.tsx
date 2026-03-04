import React, { useState } from "react";
import {
  View,
  Text,
  SectionList,
  TouchableOpacity,
  TextInput,
  Modal,
  StyleSheet,
  Alert,
} from "react-native";
import { useRouter } from "expo-router";
import { useConnectionStore } from "../../src/stores/connectionStore";
import { useSessionStore } from "../../src/stores/sessionStore";
import type { TmuxPane, TmuxWindow, TmuxSession } from "../../src/types";

export default function SessionsScreen() {
  const { api, topology, activeMachine, connected } = useConnectionStore();
  const { setActivePane, setActiveSession } = useSessionStore();
  const router = useRouter();
  const [showNewSession, setShowNewSession] = useState(false);
  const [newSessionName, setNewSessionName] = useState("");
  const [startingManager, setStartingManager] = useState(false);

  const handleStartManager = async () => {
    if (!api) return;
    setStartingManager(true);
    try {
      const result = await api.startDashboard();
      setActivePane(result.pane_id);
      router.push("/(tabs)/terminal");
    } catch (e: any) {
      Alert.alert("Error", e.message);
    } finally {
      setStartingManager(false);
    }
  };

  const handleCreateSession = async () => {
    const name = newSessionName.trim();
    if (!name || !api) return;
    try {
      await api.createSession(name);
      setNewSessionName("");
      setShowNewSession(false);
    } catch (e: any) {
      Alert.alert("Error", e.message);
    }
  };

  const handleDeleteSession = (name: string) => {
    Alert.alert("Delete Session", `Kill session "${name}"?`, [
      { text: "Cancel", style: "cancel" },
      {
        text: "Delete",
        style: "destructive",
        onPress: async () => {
          try {
            await api?.deleteSession(name);
          } catch (e: any) {
            Alert.alert("Error", e.message);
          }
        },
      },
    ]);
  };

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
      <View style={styles.container}>
        <View style={styles.header}>
          <View style={{ flexDirection: "row", alignItems: "center", flex: 1 }}>
            <View style={[styles.statusDot, { backgroundColor: "#22c55e" }]} />
            <Text style={styles.headerText}>{activeMachine.name}</Text>
          </View>
          <TouchableOpacity
            style={styles.managerBtn}
            onPress={handleStartManager}
            disabled={startingManager}
          >
            <Text style={styles.managerBtnText}>
              {startingManager ? "..." : "Start Manager"}
            </Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={styles.addBtn}
            onPress={() => setShowNewSession(true)}
          >
            <Text style={styles.addBtnText}>+</Text>
          </TouchableOpacity>
        </View>

        <Modal
          visible={showNewSession}
          transparent
          animationType="fade"
          onRequestClose={() => setShowNewSession(false)}
        >
          <View style={styles.modalOverlay}>
            <View style={styles.modalCard}>
              <Text style={styles.modalTitle}>New Session</Text>
              <TextInput
                style={styles.modalInput}
                value={newSessionName}
                onChangeText={setNewSessionName}
                placeholder="Session name"
                placeholderTextColor="#555"
                autoCapitalize="none"
                autoCorrect={false}
                autoFocus
              />
              <View style={styles.modalButtons}>
                <TouchableOpacity
                  style={styles.modalCancelBtn}
                  onPress={() => { setShowNewSession(false); setNewSessionName(""); }}
                >
                  <Text style={styles.modalCancelText}>Cancel</Text>
                </TouchableOpacity>
                <TouchableOpacity
                  style={styles.modalCreateBtn}
                  onPress={handleCreateSession}
                >
                  <Text style={styles.modalCreateText}>Create</Text>
                </TouchableOpacity>
              </View>
            </View>
          </View>
        </Modal>

        <View style={styles.emptyBody}>
          <Text style={styles.emptyText}>No tmux sessions yet.</Text>
          <Text style={styles.emptySubtext}>
            Tap + to create one.
          </Text>
        </View>
      </View>
    );
  }

  // Build sections: one per session, items are panes grouped by window
  // Pin "sessions-manager" to the top of the list
  const sortedSessions = [...topology.sessions].sort((a, b) => {
    if (a.name === "sessions-manager") return -1;
    if (b.name === "sessions-manager") return 1;
    return 0;
  });

  const sections = sortedSessions.map((session) => {
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
        <View style={{ flexDirection: "row", alignItems: "center", flex: 1 }}>
          <View style={[styles.statusDot, { backgroundColor: "#22c55e" }]} />
          <Text style={styles.headerText}>{activeMachine.name}</Text>
        </View>
        <TouchableOpacity
          style={styles.managerBtn}
          onPress={handleStartManager}
          disabled={startingManager}
        >
          <Text style={styles.managerBtnText}>
            {startingManager ? "..." : "Start Manager"}
          </Text>
        </TouchableOpacity>
        <TouchableOpacity
          style={styles.addBtn}
          onPress={() => setShowNewSession(true)}
        >
          <Text style={styles.addBtnText}>+</Text>
        </TouchableOpacity>
      </View>

      <Modal
        visible={showNewSession}
        transparent
        animationType="fade"
        onRequestClose={() => setShowNewSession(false)}
      >
        <View style={styles.modalOverlay}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>New Session</Text>
            <TextInput
              style={styles.modalInput}
              value={newSessionName}
              onChangeText={setNewSessionName}
              placeholder="Session name"
              placeholderTextColor="#555"
              autoCapitalize="none"
              autoCorrect={false}
              autoFocus
            />
            <View style={styles.modalButtons}>
              <TouchableOpacity
                style={styles.modalCancelBtn}
                onPress={() => { setShowNewSession(false); setNewSessionName(""); }}
              >
                <Text style={styles.modalCancelText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={styles.modalCreateBtn}
                onPress={handleCreateSession}
              >
                <Text style={styles.modalCreateText}>Create</Text>
              </TouchableOpacity>
            </View>
          </View>
        </View>
      </Modal>

      <SectionList
        sections={sections}
        keyExtractor={(item) => item.id}
        renderSectionHeader={({ section }) => {
          const isManager = section.title === "sessions-manager";
          return (
            <TouchableOpacity
              style={styles.sectionHeader}
              onLongPress={() => handleDeleteSession(section.title)}
            >
              <Text style={[styles.sectionTitle, isManager && { color: "#14b8a6" }]}>
                {section.title}
              </Text>
              <Text style={styles.sectionBadge}>
                {section.session.attached ? "attached" : "detached"}
              </Text>
            </TouchableOpacity>
          );
        }}
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
  emptyBody: { flex: 1, alignItems: "center", justifyContent: "center" },
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
  managerBtn: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: "#14b8a6",
    marginRight: 8,
  },
  managerBtnText: {
    color: "#14b8a6",
    fontSize: 13,
    fontWeight: "600",
  },
  addBtn: {
    width: 32,
    height: 32,
    borderRadius: 16,
    backgroundColor: "#7c3aed",
    alignItems: "center",
    justifyContent: "center",
  },
  addBtnText: { color: "#fff", fontSize: 20, fontWeight: "600", marginTop: -1 },
  modalOverlay: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.6)",
    justifyContent: "center",
    alignItems: "center",
  },
  modalCard: {
    backgroundColor: "#1a1a2e",
    borderRadius: 12,
    padding: 20,
    width: "85%",
    borderWidth: 1,
    borderColor: "#2a2a3e",
  },
  modalTitle: { color: "#e0e0e0", fontSize: 18, fontWeight: "600", marginBottom: 16 },
  modalInput: {
    backgroundColor: "#0f0f1a",
    borderWidth: 1,
    borderColor: "#2a2a3e",
    borderRadius: 8,
    padding: 12,
    color: "#e0e0e0",
    fontSize: 15,
    marginBottom: 16,
  },
  modalButtons: { flexDirection: "row", justifyContent: "flex-end", gap: 12 },
  modalCancelBtn: { paddingHorizontal: 16, paddingVertical: 10 },
  modalCancelText: { color: "#888", fontSize: 15 },
  modalCreateBtn: {
    backgroundColor: "#7c3aed",
    paddingHorizontal: 20,
    paddingVertical: 10,
    borderRadius: 8,
  },
  modalCreateText: { color: "#fff", fontSize: 15, fontWeight: "600" },
});
