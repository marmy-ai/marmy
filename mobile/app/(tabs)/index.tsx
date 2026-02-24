import React, { useState } from "react";
import {
  View,
  Text,
  FlatList,
  TextInput,
  TouchableOpacity,
  StyleSheet,
  Alert,
} from "react-native";
import { useRouter } from "expo-router";
import { useConnectionStore } from "../../src/stores/connectionStore";

export default function MachinesScreen() {
  const { machines, addMachine, removeMachine, connectToMachine } =
    useConnectionStore();
  const router = useRouter();

  const [showAdd, setShowAdd] = useState(false);
  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [token, setToken] = useState("");

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

  const handleConnect = async (machine: (typeof machines)[0]) => {
    try {
      await connectToMachine(machine);
      router.push("/(tabs)/sessions");
    } catch (e: any) {
      Alert.alert("Connection failed", e.message);
    }
  };

  return (
    <View style={styles.container}>
      <FlatList
        data={machines}
        keyExtractor={(item) => item.id}
        contentContainerStyle={styles.list}
        ListEmptyComponent={
          <View style={styles.empty}>
            <Text style={styles.emptyText}>No machines added yet.</Text>
            <Text style={styles.emptySubtext}>
              Run `marmy-agent pair` on your machine to get connection details.
            </Text>
          </View>
        }
        renderItem={({ item }) => (
          <TouchableOpacity
            style={styles.card}
            onPress={() => handleConnect(item)}
            onLongPress={() =>
              Alert.alert("Remove machine?", item.name, [
                { text: "Cancel" },
                {
                  text: "Remove",
                  style: "destructive",
                  onPress: () => removeMachine(item.id),
                },
              ])
            }
          >
            <View style={styles.cardHeader}>
              <View
                style={[
                  styles.statusDot,
                  { backgroundColor: item.online ? "#22c55e" : "#666" },
                ]}
              />
              <Text style={styles.cardTitle}>{item.name}</Text>
            </View>
            <Text style={styles.cardAddress}>{item.address}</Text>
          </TouchableOpacity>
        )}
      />

      {showAdd ? (
        <View style={styles.addForm}>
          <TextInput
            style={styles.input}
            placeholder="Machine name"
            placeholderTextColor="#666"
            value={name}
            onChangeText={setName}
          />
          <TextInput
            style={styles.input}
            placeholder="Address (host:port)"
            placeholderTextColor="#666"
            value={address}
            onChangeText={setAddress}
            autoCapitalize="none"
            keyboardType="url"
          />
          <TextInput
            style={styles.input}
            placeholder="Auth token"
            placeholderTextColor="#666"
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
    </View>
  );
}

const styles = StyleSheet.create({
  container: { flex: 1, backgroundColor: "#0f0f1a" },
  list: { padding: 16 },
  empty: { alignItems: "center", marginTop: 100 },
  emptyText: { color: "#888", fontSize: 18, marginBottom: 8 },
  emptySubtext: { color: "#555", fontSize: 14, textAlign: "center", paddingHorizontal: 40 },
  card: {
    backgroundColor: "#1a1a2e",
    borderRadius: 12,
    padding: 16,
    marginBottom: 12,
    borderWidth: 1,
    borderColor: "#2a2a3e",
  },
  cardHeader: { flexDirection: "row", alignItems: "center", marginBottom: 4 },
  statusDot: { width: 8, height: 8, borderRadius: 4, marginRight: 8 },
  cardTitle: { color: "#e0e0e0", fontSize: 18, fontWeight: "600" },
  cardAddress: { color: "#888", fontSize: 14, marginLeft: 16 },
  addForm: {
    backgroundColor: "#1a1a2e",
    padding: 16,
    borderTopWidth: 1,
    borderTopColor: "#2a2a3e",
  },
  input: {
    backgroundColor: "#0f0f1a",
    borderWidth: 1,
    borderColor: "#2a2a3e",
    borderRadius: 8,
    padding: 12,
    color: "#e0e0e0",
    fontSize: 16,
    marginBottom: 8,
  },
  addButtons: { flexDirection: "row", justifyContent: "flex-end", gap: 8, marginTop: 8 },
  cancelBtn: { padding: 12, borderRadius: 8 },
  cancelBtnText: { color: "#888", fontSize: 16 },
  addBtn: { backgroundColor: "#7c3aed", padding: 12, borderRadius: 8, paddingHorizontal: 20 },
  addBtnText: { color: "#fff", fontSize: 16, fontWeight: "600" },
  fab: {
    position: "absolute",
    right: 20,
    bottom: 20,
    width: 56,
    height: 56,
    borderRadius: 28,
    backgroundColor: "#7c3aed",
    alignItems: "center",
    justifyContent: "center",
    elevation: 4,
    shadowColor: "#7c3aed",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.3,
    shadowRadius: 4,
  },
  fabText: { color: "#fff", fontSize: 28, lineHeight: 30 },
});
