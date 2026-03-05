import React, { useState } from "react";
import {
  View,
  Text,
  ScrollView,
  TouchableOpacity,
  Pressable,
  TextInput,
  Modal,
  StyleSheet,
  Alert,
} from "react-native";
import { useRouter } from "expo-router";
import { useConnectionStore } from "../../src/stores/connectionStore";
import { useSessionStore } from "../../src/stores/sessionStore";
import type { TmuxPane, TmuxSession } from "../../src/types";

export default function SessionsScreen() {
  const { api, topology, activeMachine, connected } = useConnectionStore();
  const { setActivePane, setActiveSession, setActiveSessionName } = useSessionStore();
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

  const handleSessionPress = (session: TmuxSession) => {
    // Find the first pane in this session and open it
    if (!topology) return;
    const pane = topology.panes.find((p) => p.session_id === session.id);
    if (pane) {
      setActivePane(pane.id);
      setActiveSession(session.id);
      setActiveSessionName(session.name);
      router.push("/(tabs)/terminal");
    }
  };

  /** Shorten a path to just the last directory name */
  const shortPath = (fullPath: string) => {
    if (!fullPath) return "";
    const parts = fullPath.split("/").filter(Boolean);
    return parts[parts.length - 1] || fullPath;
  };

  /** Get the working directory for a session from its first pane */
  const getSessionPath = (session: TmuxSession): string => {
    if (!topology) return "";
    const pane = topology.panes.find((p) => p.session_id === session.id);
    return pane?.current_path || "";
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

  // Split sessions into manager and the rest
  const managerSession = topology?.sessions.find(
    (s) => s.name === "sessions-manager"
  );
  const otherSessions = (topology?.sessions || []).filter(
    (s) => s.name !== "sessions-manager"
  );

  const renderHeader = () => (
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
  );

  const renderModal = () => (
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
              onPress={() => {
                setShowNewSession(false);
                setNewSessionName("");
              }}
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
  );

  const renderSessionPill = (session: TmuxSession, isManager = false) => {
    const path = getSessionPath(session);
    return (
      <TouchableOpacity
        key={session.id}
        style={[
          styles.sessionPill,
          isManager && styles.managerPill,
        ]}
        onPress={() => handleSessionPress(session)}
        onLongPress={() => handleDeleteSession(session.name)}
      >
        <Text
          style={[styles.sessionName, isManager && styles.managerName]}
          numberOfLines={1}
        >
          {session.name}
        </Text>
        {path ? (
          <Text style={styles.sessionPath} numberOfLines={1}>
            {shortPath(path)}
          </Text>
        ) : null}
      </TouchableOpacity>
    );
  };

  if (!topology || topology.sessions.length === 0) {
    return (
      <View style={styles.container}>
        {renderHeader()}
        {renderModal()}
        <View style={styles.emptyBody}>
          <Text style={styles.emptyText}>No tmux sessions yet.</Text>
          <Text style={styles.emptySubtext}>Tap + to create one.</Text>
        </View>
      </View>
    );
  }

  return (
    <View style={styles.container}>
      {renderHeader()}
      {renderModal()}

      <ScrollView contentContainerStyle={styles.list}>
        {/* Manager section */}
        {managerSession && (
          <View style={styles.managerSection}>
            {renderSessionPill(managerSession, true)}

            {/* Child sessions nested under manager */}
            {otherSessions.length > 0 && (
              <View style={styles.childSessions}>
                <View style={styles.treeLine} />
                <View style={styles.childList}>
                  {otherSessions.map((session) =>
                    renderSessionPill(session)
                  )}
                </View>
              </View>
            )}
          </View>
        )}

        {/* If no manager, just show sessions flat */}
        {!managerSession &&
          otherSessions.map((session) => renderSessionPill(session))}
      </ScrollView>
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

  // Session pills
  sessionPill: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    backgroundColor: "#1a1a2e",
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 14,
    marginBottom: 8,
    borderWidth: 1,
    borderColor: "#2a2a3e",
  },
  sessionName: {
    color: "#e0e0e0",
    fontSize: 15,
    fontWeight: "600",
    flexShrink: 1,
  },
  sessionPath: {
    color: "#666",
    fontSize: 13,
    marginLeft: 12,
  },

  // Manager-specific
  managerSection: {
    marginBottom: 4,
  },
  managerPill: {
    borderColor: "#14b8a6",
    backgroundColor: "#0f1f1d",
  },
  managerName: {
    color: "#14b8a6",
  },
  childSessions: {
    flexDirection: "row",
    marginLeft: 12,
  },
  treeLine: {
    width: 2,
    backgroundColor: "#2a2a3e",
    borderRadius: 1,
    marginRight: 12,
  },
  childList: {
    flex: 1,
    paddingTop: 4,
  },

  // Header buttons
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
  addBtnText: {
    color: "#fff",
    fontSize: 20,
    fontWeight: "600",
    marginTop: -1,
  },

  // Modal
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
  modalTitle: {
    color: "#e0e0e0",
    fontSize: 18,
    fontWeight: "600",
    marginBottom: 16,
  },
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
  modalButtons: {
    flexDirection: "row",
    justifyContent: "flex-end",
    gap: 12,
  },
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
