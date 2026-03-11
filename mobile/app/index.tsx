import React, { useState } from "react";
import {
  View,
  Text,
  FlatList,
  ScrollView,
  TextInput,
  TouchableOpacity,
  Modal,
  StyleSheet,
  Alert,
  KeyboardAvoidingView,
  Platform,
} from "react-native";
import { useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { useConnectionStore } from "../src/stores/connectionStore";
import { theme } from "../src/theme";
import RetroComputer from "../src/components/RetroComputer";
import type { Machine } from "../src/types";

export default function HomeScreen() {
  const { machines, addMachine, updateMachine, removeMachine, connectToMachine } =
    useConnectionStore();
  const router = useRouter();
  const insets = useSafeAreaInsets();

  const [showAdd, setShowAdd] = useState(false);
  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [token, setToken] = useState("");

  const [editMachine, setEditMachine] = useState<Machine | null>(null);
  const [editName, setEditName] = useState("");
  const [editAddress, setEditAddress] = useState("");
  const [editToken, setEditToken] = useState("");

  const handleAdd = () => {
    if (!name.trim() || !address.trim() || !token.trim()) {
      Alert.alert("Error", "All fields are required");
      return;
    }
    addMachine({ name: name.trim(), address: address.trim(), token: token.trim() });
    setName("");
    setAddress("");
    setToken("");
    setShowAdd(false);
  };

  const handleEdit = (machine: Machine) => {
    setEditMachine(machine);
    setEditName(machine.name);
    setEditAddress(machine.address);
    setEditToken(machine.token);
  };

  const handleSaveEdit = () => {
    if (!editMachine) return;
    updateMachine(editMachine.id, {
      name: editName.trim() || editMachine.name,
      address: editAddress.trim() || editMachine.address,
      token: editToken.trim() || editMachine.token,
    });
    setEditMachine(null);
  };

  const handleConnect = async (machine: (typeof machines)[0]) => {
    try {
      await connectToMachine(machine);
      router.push("/workers");
    } catch (e: any) {
      Alert.alert("Connection failed", e.message);
    }
  };

  return (
    <KeyboardAvoidingView
      style={[styles.container, { paddingTop: insets.top }]}
      behavior={Platform.OS === "ios" ? "padding" : "height"}
      keyboardVerticalOffset={Platform.OS === "ios" ? 90 : 0}
    >
      <FlatList
        data={machines}
        keyExtractor={(item) => item.id}
        numColumns={2}
        contentContainerStyle={[styles.grid, { paddingBottom: insets.bottom, flexGrow: 1, justifyContent: "center" }]}
        ListEmptyComponent={
          <View style={styles.empty}>
            {/* Powered-off retro computer */}
            <View style={styles.offMonitor}>
              <View style={styles.offScreen}>
                <Text style={styles.offText}>No machines</Text>
                <Text style={styles.offSubtext}>Tap + to add one</Text>
              </View>
              <Text style={styles.offBrand}>MARMY</Text>
            </View>
            <Text style={styles.emptySubtext}>
              Run `marmy-agent pair` on your machine to get connection details.
            </Text>
          </View>
        }
        renderItem={({ item }) => (
          <RetroComputer
            name={item.name}
            onPress={() => handleConnect(item)}
            onLongPress={() =>
              Alert.alert(item.name, undefined, [
                { text: "Cancel", style: "cancel" },
                { text: "Edit", onPress: () => handleEdit(item) },
                {
                  text: "Remove",
                  style: "destructive",
                  onPress: () => removeMachine(item.id),
                },
              ])
            }
          />
        )}
      />

      {showAdd ? (
        <View style={styles.addForm}>
          <TextInput
            style={styles.input}
            placeholder="Machine name"
            placeholderTextColor={theme.textDim}
            value={name}
            onChangeText={setName}
          />
          <TextInput
            style={styles.input}
            placeholder="Address (host:port)"
            placeholderTextColor={theme.textDim}
            value={address}
            onChangeText={setAddress}
            autoCapitalize="none"
            keyboardType="url"
          />
          <TextInput
            style={styles.input}
            placeholder="Auth token"
            placeholderTextColor={theme.textDim}
            value={token}
            onChangeText={setToken}
            autoCapitalize="none"
            secureTextEntry
          />
          <View style={styles.addButtons}>
            <TouchableOpacity
              style={styles.cancelBtn}
              onPress={() => setShowAdd(false)}
            >
              <Text style={styles.cancelBtnText}>Cancel</Text>
            </TouchableOpacity>
            <TouchableOpacity style={styles.addBtn} onPress={handleAdd}>
              <Text style={styles.addBtnText}>Add Machine</Text>
            </TouchableOpacity>
          </View>
        </View>
      ) : (
        <TouchableOpacity
          style={styles.fab}
          onPress={() => setShowAdd(true)}
        >
          <Text style={styles.fabText}>+</Text>
        </TouchableOpacity>
      )}
      <Modal
        visible={!!editMachine}
        transparent
        animationType="fade"
        onRequestClose={() => setEditMachine(null)}
      >
        <KeyboardAvoidingView
          style={styles.modalOverlay}
          behavior={Platform.OS === "ios" ? "padding" : "height"}
        >
          <ScrollView
            contentContainerStyle={styles.modalScrollContent}
            bounces={false}
            keyboardShouldPersistTaps="handled"
          >
            <View style={styles.modalCard}>
            <Text style={styles.modalTitle}>Edit Machine</Text>
            <TextInput
              style={styles.input}
              placeholder="Machine name"
              placeholderTextColor={theme.textDim}
              value={editName}
              onChangeText={setEditName}
            />
            <TextInput
              style={styles.input}
              placeholder="Address (host:port)"
              placeholderTextColor={theme.textDim}
              value={editAddress}
              onChangeText={setEditAddress}
              autoCapitalize="none"
              keyboardType="url"
            />
            <TextInput
              style={styles.input}
              placeholder="Auth token"
              placeholderTextColor={theme.textDim}
              value={editToken}
              onChangeText={setEditToken}
              autoCapitalize="none"
            />
            <View style={styles.addButtons}>
              <TouchableOpacity
                style={styles.cancelBtn}
                onPress={() => setEditMachine(null)}
              >
                <Text style={styles.cancelBtnText}>Cancel</Text>
              </TouchableOpacity>
              <TouchableOpacity style={styles.addBtn} onPress={handleSaveEdit}>
                <Text style={styles.addBtnText}>Save</Text>
              </TouchableOpacity>
            </View>
          </View>
          </ScrollView>
        </KeyboardAvoidingView>
      </Modal>
    </KeyboardAvoidingView>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: theme.bgDeep },
  grid: { padding: 10 },
  empty: { alignItems: "center", marginTop: 80, paddingHorizontal: 40 },
  offMonitor: {
    width: 180,
    backgroundColor: theme.bgCard,
    borderRadius: 8,
    borderWidth: 3,
    borderColor: theme.border,
    padding: 8,
    paddingBottom: 6,
    marginBottom: 20,
  },
  offScreen: {
    backgroundColor: "#0a0a14",
    borderRadius: 4,
    padding: 16,
    alignItems: "center",
  },
  offText: { color: theme.textSecondary, fontSize: 14, fontFamily: "monospace" },
  offSubtext: { color: theme.textTertiary, fontSize: 12, fontFamily: "monospace", marginTop: 4 },
  offBrand: {
    color: theme.textDim,
    fontSize: 9,
    fontWeight: "800",
    fontFamily: "monospace",
    textAlign: "center",
    letterSpacing: 2,
    marginTop: 6,
  },
  emptySubtext: { color: theme.textTertiary, fontSize: 14, textAlign: "center" },
  addForm: {
    backgroundColor: theme.bgCard,
    padding: 16,
    borderTopWidth: 1,
    borderTopColor: theme.border,
  },
  input: {
    backgroundColor: theme.bgDeep,
    borderWidth: 1,
    borderColor: theme.border,
    borderRadius: 8,
    padding: 12,
    color: theme.textPrimary,
    fontSize: 16,
    marginBottom: 8,
  },
  addButtons: { flexDirection: "row", justifyContent: "flex-end", gap: 8, marginTop: 8 },
  cancelBtn: { padding: 12, borderRadius: 8 },
  cancelBtnText: { color: theme.textSecondary, fontSize: 16 },
  addBtn: { backgroundColor: theme.primary, padding: 12, borderRadius: 8, paddingHorizontal: 20 },
  addBtnText: { color: "#fff", fontSize: 16, fontWeight: "600" },
  fab: {
    position: "absolute",
    right: 20,
    bottom: 20,
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: theme.primary,
    alignItems: "center",
    justifyContent: "center",
    elevation: 4,
    shadowColor: theme.primary,
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.3,
    shadowRadius: 4,
  },
  fabText: { color: "#fff", fontSize: 28, lineHeight: 30 },
  modalOverlay: {
    flex: 1,
    backgroundColor: "rgba(0,0,0,0.6)",
  },
  modalScrollContent: {
    flexGrow: 1,
    justifyContent: "center",
  },
  modalCard: {
    backgroundColor: theme.bgCard,
    borderRadius: 12,
    padding: 20,
    marginHorizontal: "7.5%",
    borderWidth: 1,
    borderColor: theme.border,
  },
  modalTitle: { color: theme.textPrimary, fontSize: 18, fontWeight: "600", marginBottom: 16 },
});
