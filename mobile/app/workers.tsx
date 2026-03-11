import React, { useState, useEffect } from "react";
import {
  View,
  Text,
  ScrollView,
  FlatList,
  TouchableOpacity,
  TextInput,
  Modal,
  Switch,
  StyleSheet,
  Alert,
} from "react-native";
import { useRouter } from "expo-router";
import { useConnectionStore } from "../src/stores/connectionStore";
import { useSessionStore } from "../src/stores/sessionStore";
import { theme } from "../src/theme";
import DirPicker from "../src/components/DirPicker";
import type { TmuxSession } from "../src/types";

/** Small glasses icon drawn with Views */
function MarmyGlasses({ teal }: { teal?: boolean }) {
  const color = teal ? theme.manager : theme.primary;
  return (
    <View style={glassesStyles.row}>
      <View style={[glassesStyles.lens, { borderColor: color }]} />
      <View style={[glassesStyles.bridge, { backgroundColor: color }]} />
      <View style={[glassesStyles.lens, { borderColor: color }]} />
    </View>
  );
}

const glassesStyles = StyleSheet.create({
  row: { flexDirection: "row", alignItems: "center", justifyContent: "center" },
  lens: {
    width: 14,
    height: 10,
    borderRadius: 3,
    borderWidth: 2,
  },
  bridge: {
    width: 4,
    height: 2,
  },
});

export default function WorkersScreen() {
  const { api, topology, activeMachine, connected } = useConnectionStore();
  const { setActivePane, setActiveSession, setActiveSessionName } = useSessionStore();
  const router = useRouter();
  const [showNewSession, setShowNewSession] = useState(false);
  const [newSessionName, setNewSessionName] = useState("");
  const [startingManager, setStartingManager] = useState(false);
  const [sessionMode, setSessionMode] = useState<"claude" | "terminal">("claude");
  const [selectedDir, setSelectedDir] = useState<string | null>(null);
  const [skipPermissions, setSkipPermissions] = useState(true);
  const [recentDirs, setRecentDirs] = useState<string[]>([]);
  const [loadingDirs, setLoadingDirs] = useState(false);
  const [creating, setCreating] = useState(false);
  const [showDirPicker, setShowDirPicker] = useState(false);

  useEffect(() => {
    if (showNewSession && api) {
      setLoadingDirs(true);
      api.getRecentDirs().then(setRecentDirs).catch(() => {}).finally(() => setLoadingDirs(false));
    }
  }, [showNewSession, api]);

  const resetModal = () => {
    setShowNewSession(false);
    setNewSessionName("");
    setSessionMode("claude");
    setSelectedDir(null);
    setSkipPermissions(true);
    setShowDirPicker(false);
    setCreating(false);
  };

  const handleStartManager = async () => {
    if (!api) return;
    setStartingManager(true);
    try {
      const result = await api.startDashboard();
      setActivePane(result.pane_id);
      router.push("/terminal");
    } catch (e: any) {
      Alert.alert("Error", e.message);
    } finally {
      setStartingManager(false);
    }
  };

  const handleCreateSession = async () => {
    const name = newSessionName.trim();
    if (!name || !api) return;
    setCreating(true);
    try {
      const result = await api.createSession(name, {
        mode: sessionMode,
        working_dir: selectedDir ?? undefined,
        skip_permissions: sessionMode === "claude" ? skipPermissions : undefined,
      });
      setActivePane(result.pane_id);
      setActiveSessionName(result.session_name);
      resetModal();
      router.push("/terminal");
    } catch (e: any) {
      Alert.alert("Error", e.message);
      setCreating(false);
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

  const handleChat = (session: TmuxSession) => {
    if (!topology) return;
    const pane = topology.panes.find((p) => p.session_id === session.id);
    if (pane) {
      if (session.unread && api) {
        api.markSessionRead(session.name).catch(() => {});
      }
      setActivePane(pane.id);
      setActiveSession(session.id);
      setActiveSessionName(session.name);
      router.push("/terminal");
    }
  };

  const handleFiles = (session: TmuxSession) => {
    router.push({
      pathname: "/files",
      params: { sessionId: session.id, sessionName: session.name },
    });
  };

  const shortPath = (fullPath: string) => {
    if (!fullPath) return "";
    const parts = fullPath.split("/").filter(Boolean);
    return parts[parts.length - 1] || fullPath;
  };

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
          Go back and connect to a machine first.
        </Text>
      </View>
    );
  }

  const managerSession = topology?.sessions.find(
    (s) => s.name === "sessions-manager"
  );
  const otherSessions = (topology?.sessions || []).filter(
    (s) => s.name !== "sessions-manager"
  );

  const renderHeader = () => (
    <View style={styles.header}>
      <View style={{ flexDirection: "row", alignItems: "center", flex: 1 }}>
        <View style={[styles.statusDot, { backgroundColor: theme.success }]} />
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
      transparent={!showDirPicker}
      animationType={showDirPicker ? "slide" : "fade"}
      onRequestClose={resetModal}
      presentationStyle={showDirPicker ? "fullScreen" : undefined}
    >
      {showDirPicker && api ? (
        <DirPicker
          api={api}
          recentDirs={recentDirs}
          onSelect={(path) => {
            setSelectedDir(path);
            setShowDirPicker(false);
          }}
          onCancel={() => setShowDirPicker(false)}
        />
      ) : (
        <View style={styles.modalOverlay}>
          <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>New Session</Text>

            <View style={styles.modeToggle}>
              <TouchableOpacity
                style={[
                  styles.modeBtn,
                  sessionMode === "claude" && styles.modeBtnActive,
                ]}
                onPress={() => setSessionMode("claude")}
              >
                <Text
                  style={[
                    styles.modeBtnText,
                    sessionMode === "claude" && styles.modeBtnTextActive,
                  ]}
                >
                  Claude
                </Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[
                  styles.modeBtn,
                  sessionMode === "terminal" && styles.modeBtnActive,
                ]}
                onPress={() => setSessionMode("terminal")}
              >
                <Text
                  style={[
                    styles.modeBtnText,
                    sessionMode === "terminal" && styles.modeBtnTextActive,
                  ]}
                >
                  Terminal
                </Text>
              </TouchableOpacity>
            </View>

            <TextInput
              style={styles.modalInput}
              value={newSessionName}
              onChangeText={setNewSessionName}
              placeholder="Session name"
              placeholderTextColor={theme.textTertiary}
              autoCapitalize="none"
              autoCorrect={false}
              autoFocus
            />

            <TouchableOpacity
              style={styles.dirSelector}
              onPress={() => setShowDirPicker(true)}
            >
              <Text style={styles.dirLabel}>Working directory</Text>
              <Text
                style={[
                  styles.dirValue,
                  !selectedDir && styles.dirValuePlaceholder,
                ]}
                numberOfLines={1}
              >
                {selectedDir ? shortPath(selectedDir) : "No directory selected"}
              </Text>
            </TouchableOpacity>

            {sessionMode === "claude" && (
              <View style={styles.toggleRow}>
                <View style={{ flex: 1 }}>
                  <Text style={styles.toggleLabel}>Skip permissions</Text>
                  <Text style={styles.toggleSubtext}>
                    --dangerously-skip-permissions
                  </Text>
                </View>
                <Switch
                  value={skipPermissions}
                  onValueChange={setSkipPermissions}
                  trackColor={{ false: theme.border, true: theme.primary }}
                  thumbColor={skipPermissions ? "#fff" : theme.textSecondary}
                />
              </View>
            )}

            <View style={styles.modalButtons}>
              <TouchableOpacity
                style={styles.modalCancelBtn}
                onPress={resetModal}
              >
                <Text style={styles.modalCancelText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity
                style={[styles.modalCreateBtn, creating && { opacity: 0.6 }]}
                onPress={handleCreateSession}
                disabled={creating}
              >
                <Text style={styles.modalCreateText}>
                  {creating ? "Creating..." : "Create"}
                </Text>
              </TouchableOpacity>
            </View>
          </View>
        </View>
      )}
    </Modal>
  );

  /** Manager card — full width at top */
  const renderManagerCard = (session: TmuxSession) => {
    const path = getSessionPath(session);
    const isUnread = !!session.unread;
    return (
      <View
        key={session.id}
        style={[styles.managerCard, isUnread && styles.unreadCard]}
      >
        <TouchableOpacity
          style={styles.cardHeader}
          onLongPress={() => handleDeleteSession(session.name)}
        >
          <View style={{ flexDirection: "row", alignItems: "center", flex: 1 }}>
            <MarmyGlasses teal />
            {isUnread && <View style={styles.unreadDot} />}
            <Text style={styles.managerName} numberOfLines={1}>
              {session.name}
            </Text>
          </View>
          {path ? (
            <Text style={styles.workerPath} numberOfLines={1}>
              ~/{shortPath(path)}
            </Text>
          ) : null}
        </TouchableOpacity>
        <View style={styles.actionRow}>
          <TouchableOpacity
            style={[styles.actionBtn, styles.chatBtnManager]}
            onPress={() => handleChat(session)}
          >
            <Text style={styles.actionBtnText}>Chat</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.actionBtn, styles.filesBtn]}
            onPress={() => handleFiles(session)}
          >
            <Text style={styles.filesBtnText}>Files</Text>
          </TouchableOpacity>
        </View>
      </View>
    );
  };

  /** Worker card — used in 2-col grid */
  const renderWorkerGridItem = ({ item }: { item: TmuxSession }) => {
    const path = getSessionPath(item);
    const isUnread = !!item.unread;
    return (
      <View style={[styles.workerGridCard, isUnread && styles.unreadCard]}>
        {/* Glasses on top */}
        <View style={styles.glassesHeader}>
          <MarmyGlasses />
        </View>

        <TouchableOpacity
          style={styles.gridCardBody}
          onLongPress={() => handleDeleteSession(item.name)}
          activeOpacity={1}
        >
          <View style={{ flexDirection: "row", alignItems: "center" }}>
            {isUnread && <View style={styles.unreadDot} />}
            <Text style={styles.workerName} numberOfLines={1}>
              {item.name}
            </Text>
          </View>
          {path ? (
            <Text style={styles.workerPathSmall} numberOfLines={1}>
              ~/{shortPath(path)}
            </Text>
          ) : null}
        </TouchableOpacity>

        <View style={styles.actionRow}>
          <TouchableOpacity
            style={[styles.actionBtn, styles.chatBtn]}
            onPress={() => handleChat(item)}
          >
            <Text style={styles.actionBtnText}>Chat</Text>
          </TouchableOpacity>
          <TouchableOpacity
            style={[styles.actionBtn, styles.filesBtn]}
            onPress={() => handleFiles(item)}
          >
            <Text style={styles.filesBtnText}>Files</Text>
          </TouchableOpacity>
        </View>
      </View>
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

      <FlatList
        data={otherSessions}
        keyExtractor={(item) => item.id}
        numColumns={2}
        contentContainerStyle={styles.list}
        ListHeaderComponent={
          managerSession ? (
            <View style={styles.managerSection}>
              {renderManagerCard(managerSession)}
            </View>
          ) : null
        }
        renderItem={renderWorkerGridItem}
        ListEmptyComponent={
          !managerSession ? (
            <View style={styles.emptyBody}>
              <Text style={styles.emptySubtext}>No workers yet.</Text>
            </View>
          ) : null
        }
      />
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: theme.bgDeep },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: theme.bgDeep,
  },
  emptyBody: { flex: 1, alignItems: "center", justifyContent: "center", padding: 32 },
  emptyText: { color: theme.textSecondary, fontSize: 18, marginBottom: 8 },
  emptySubtext: { color: theme.textTertiary, fontSize: 14 },
  header: {
    flexDirection: "row",
    alignItems: "center",
    padding: 16,
    borderBottomWidth: 1,
    borderBottomColor: theme.border,
  },
  statusDot: { width: 8, height: 8, borderRadius: 4, marginRight: 8 },
  headerText: { color: theme.textPrimary, fontSize: 16, fontWeight: "600" },
  list: { padding: 10 },

  // Manager card — full width
  managerSection: {
    marginBottom: 8,
  },
  managerCard: {
    backgroundColor: theme.bgManagerCard,
    borderRadius: 12,
    padding: 14,
    borderWidth: 1,
    borderColor: theme.manager,
  },
  managerName: {
    color: theme.manager,
    fontSize: 15,
    fontWeight: "600",
    flexShrink: 1,
    marginLeft: 8,
  },
  cardHeader: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    marginBottom: 10,
  },

  // Worker grid card — half width
  workerGridCard: {
    flex: 1,
    margin: 4,
    backgroundColor: theme.bgCard,
    borderRadius: 12,
    borderWidth: 1,
    borderColor: theme.border,
    overflow: "hidden",
  },
  glassesHeader: {
    paddingTop: 10,
    paddingBottom: 6,
    alignItems: "center",
    borderBottomWidth: 1,
    borderBottomColor: theme.border,
    backgroundColor: theme.bgElevated,
  },
  gridCardBody: {
    padding: 10,
    paddingBottom: 8,
  },
  workerName: {
    color: theme.textPrimary,
    fontSize: 14,
    fontWeight: "600",
    flexShrink: 1,
  },
  workerPath: {
    color: theme.textDim,
    fontSize: 13,
    marginLeft: 12,
  },
  workerPathSmall: {
    color: theme.textDim,
    fontSize: 11,
    marginTop: 2,
  },
  unreadCard: {
    borderColor: theme.primary,
  },
  unreadDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: theme.primary,
    marginRight: 6,
  },

  // Action buttons
  actionRow: {
    flexDirection: "row",
    gap: 6,
    padding: 8,
    paddingTop: 0,
  },
  actionBtn: {
    flex: 1,
    height: 40,
    borderRadius: 8,
    alignItems: "center",
    justifyContent: "center",
  },
  chatBtn: {
    backgroundColor: theme.primary,
  },
  chatBtnManager: {
    backgroundColor: theme.manager,
  },
  filesBtn: {
    backgroundColor: theme.border,
    borderWidth: 1,
    borderColor: theme.borderLight,
  },
  actionBtnText: {
    color: "#fff",
    fontSize: 14,
    fontWeight: "600",
  },
  filesBtnText: {
    color: theme.textPrimary,
    fontSize: 14,
    fontWeight: "600",
  },

  // Header buttons
  managerBtn: {
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 16,
    borderWidth: 1,
    borderColor: theme.manager,
    marginRight: 8,
  },
  managerBtnText: {
    color: theme.manager,
    fontSize: 13,
    fontWeight: "600",
  },
  addBtn: {
    width: 32,
    height: 32,
    borderRadius: 16,
    backgroundColor: theme.primary,
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
    backgroundColor: theme.bgCard,
    borderRadius: 12,
    padding: 20,
    width: "85%",
    borderWidth: 1,
    borderColor: theme.border,
  },
  modalTitle: {
    color: theme.textPrimary,
    fontSize: 18,
    fontWeight: "600",
    marginBottom: 16,
  },
  modalInput: {
    backgroundColor: theme.bgDeep,
    borderWidth: 1,
    borderColor: theme.border,
    borderRadius: 8,
    padding: 12,
    color: theme.textPrimary,
    fontSize: 15,
    marginBottom: 16,
  },
  modalButtons: {
    flexDirection: "row",
    justifyContent: "flex-end",
    gap: 12,
  },
  modalCancelBtn: { paddingHorizontal: 16, paddingVertical: 10 },
  modalCancelText: { color: theme.textSecondary, fontSize: 15 },
  modalCreateBtn: {
    backgroundColor: theme.primary,
    paddingHorizontal: 20,
    paddingVertical: 10,
    borderRadius: 8,
  },
  modalCreateText: { color: "#fff", fontSize: 15, fontWeight: "600" },

  // Mode toggle
  modeToggle: {
    flexDirection: "row",
    backgroundColor: theme.bgDeep,
    borderRadius: 8,
    marginBottom: 16,
    padding: 3,
  },
  modeBtn: {
    flex: 1,
    paddingVertical: 8,
    borderRadius: 6,
    alignItems: "center",
  },
  modeBtnActive: {
    backgroundColor: theme.primary,
  },
  modeBtnText: {
    color: theme.textSecondary,
    fontSize: 14,
    fontWeight: "600",
  },
  modeBtnTextActive: {
    color: "#fff",
  },

  // Dir selector
  dirSelector: {
    backgroundColor: theme.bgDeep,
    borderWidth: 1,
    borderColor: theme.border,
    borderRadius: 8,
    padding: 12,
    marginBottom: 12,
  },
  dirLabel: {
    color: theme.textSecondary,
    fontSize: 12,
    marginBottom: 4,
  },
  dirValue: {
    color: theme.textPrimary,
    fontSize: 15,
  },
  dirValuePlaceholder: {
    color: theme.textTertiary,
  },

  // Toggle row
  toggleRow: {
    flexDirection: "row",
    alignItems: "center",
    marginBottom: 16,
  },
  toggleLabel: {
    color: theme.textPrimary,
    fontSize: 14,
    fontWeight: "500",
  },
  toggleSubtext: {
    color: theme.textDim,
    fontSize: 11,
    marginTop: 2,
  },
});
