import React, { useRef, useState } from "react";
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
  Linking,
  Platform,
} from "react-native";
import { useRouter } from "expo-router";
import { useSafeAreaInsets } from "react-native-safe-area-context";
import { CameraView, useCameraPermissions } from "expo-camera";
import * as Haptics from "expo-haptics";
import { Ionicons } from "@expo/vector-icons";
import { useConnectionStore } from "../src/stores/connectionStore";
import { theme } from "../src/theme";
import RetroComputer from "../src/components/RetroComputer";
import type { Machine } from "../src/types";

// Payload MacMarmy encodes in its pairing QR:
// {"marmy":1,"name":"<host>","addrs":["<tailscale ip:port>","<lan ip:port>"],"token":"..."}
function parsePairingQr(data: string): { name: string; addrs: string[]; token: string } | null {
  try {
    const obj = JSON.parse(data);
    if (obj?.marmy !== 1 || typeof obj.token !== "string" || !obj.token) return null;
    const addrs = Array.isArray(obj.addrs)
      ? obj.addrs.filter((a: unknown): a is string => typeof a === "string" && a.length > 0)
      : [];
    if (addrs.length === 0) return null;
    return { name: typeof obj.name === "string" ? obj.name : "", addrs, token: obj.token };
  } catch {
    return null;
  }
}

export default function HomeScreen() {
  const { machines, addMachine, updateMachine, removeMachine, connectToMachine } =
    useConnectionStore();
  const router = useRouter();
  const insets = useSafeAreaInsets();

  const [showAdd, setShowAdd] = useState(false);
  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [token, setToken] = useState("");
  // All addresses from a scanned QR (Tailscale first); cleared if the user
  // edits the address field manually afterwards.
  const [scannedAddrs, setScannedAddrs] = useState<string[] | null>(null);

  const [showScanner, setShowScanner] = useState(false);
  const [cameraPermission, requestCameraPermission] = useCameraPermissions();
  const scanHandled = useRef(false);

  const [editMachine, setEditMachine] = useState<Machine | null>(null);
  const [editName, setEditName] = useState("");
  const [editAddress, setEditAddress] = useState("");
  const [editToken, setEditToken] = useState("");

  const handleAdd = () => {
    if (!name.trim() || !address.trim() || !token.trim()) {
      Alert.alert("Error", "All fields are required");
      return;
    }
    addMachine({
      name: name.trim(),
      address: address.trim(),
      addresses: scannedAddrs ?? undefined,
      token: token.trim(),
    });
    setName("");
    setAddress("");
    setToken("");
    setScannedAddrs(null);
    setShowAdd(false);
  };

  const openScanner = async () => {
    if (!cameraPermission?.granted) {
      const res = await requestCameraPermission();
      if (!res.granted) {
        Alert.alert(
          "Camera access needed",
          "Allow camera access to scan the pairing QR code from MacMarmy.",
          [
            { text: "Cancel", style: "cancel" },
            { text: "Open Settings", onPress: () => Linking.openSettings() },
          ]
        );
        return;
      }
    }
    scanHandled.current = false;
    setShowScanner(true);
  };

  const handleScanned = ({ data }: { data: string }) => {
    if (scanHandled.current) return;
    const pairing = parsePairingQr(data);
    if (!pairing) return; // not a Marmy QR — keep scanning
    scanHandled.current = true;
    Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    setShowScanner(false);
    setShowAdd(true);
    if (pairing.name && !name.trim()) setName(pairing.name);
    setAddress(pairing.addrs[0]);
    setToken(pairing.token);
    setScannedAddrs(pairing.addrs);
  };

  const handleEdit = (machine: Machine) => {
    setEditMachine(machine);
    setEditName(machine.name);
    setEditAddress(machine.address);
    setEditToken(machine.token);
  };

  const handleSaveEdit = () => {
    if (!editMachine) return;
    const newAddress = editAddress.trim() || editMachine.address;
    updateMachine(editMachine.id, {
      name: editName.trim() || editMachine.name,
      address: newAddress,
      // A manual address edit overrides any QR-scanned candidate list.
      ...(newAddress !== editMachine.address ? { addresses: undefined } : {}),
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
              {'In MacMarmy\'s menu, choose "Pair iPhone…" and scan the QR — or run `marmy-agent pair` for the details.'}
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
          <TouchableOpacity
            style={styles.scanBtn}
            onPress={openScanner}
            accessibilityRole="button"
            accessibilityLabel="Scan pairing QR code"
          >
            <Ionicons name="qr-code-outline" size={18} color={theme.primary} />
            <Text style={styles.scanBtnText}>Scan QR from MacMarmy</Text>
          </TouchableOpacity>
          {scannedAddrs && scannedAddrs.length > 1 && (
            <Text style={styles.scanHint}>
              {scannedAddrs.length} addresses scanned — Tailscale preferred, LAN as fallback.
            </Text>
          )}
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
            onChangeText={(v) => {
              setAddress(v);
              setScannedAddrs(null);
            }}
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
              onPress={() => {
                setShowAdd(false);
                setScannedAddrs(null);
              }}
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
        visible={showScanner}
        animationType="slide"
        onRequestClose={() => setShowScanner(false)}
      >
        <View style={styles.scannerContainer}>
          <CameraView
            style={StyleSheet.absoluteFill}
            facing="back"
            barcodeScannerSettings={{ barcodeTypes: ["qr"] }}
            onBarcodeScanned={handleScanned}
          />
          <View style={[styles.scannerOverlay, { paddingTop: insets.top + 12 }]} pointerEvents="box-none">
            <Text style={styles.scannerTitle}>
              {'Scan the QR from MacMarmy\'s "Pair iPhone…" window'}
            </Text>
            <View style={styles.scannerFrame} />
            <TouchableOpacity
              style={[styles.scannerClose, { marginBottom: insets.bottom + 24 }]}
              onPress={() => setShowScanner(false)}
              accessibilityRole="button"
              accessibilityLabel="Close scanner"
            >
              <Text style={styles.scannerCloseText}>Cancel</Text>
            </TouchableOpacity>
          </View>
        </View>
      </Modal>

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
  scanBtn: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    borderWidth: 1,
    borderColor: theme.primary,
    borderRadius: 8,
    padding: 12,
    marginBottom: 12,
  },
  scanBtnText: { color: theme.primary, fontSize: 15, fontWeight: "600" },
  scanHint: {
    color: theme.textTertiary,
    fontSize: 12,
    marginBottom: 8,
    textAlign: "center",
  },
  scannerContainer: { flex: 1, backgroundColor: "#000" },
  scannerOverlay: {
    ...StyleSheet.absoluteFillObject,
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 24,
  },
  scannerTitle: {
    color: "#fff",
    fontSize: 15,
    fontWeight: "600",
    textAlign: "center",
    backgroundColor: "rgba(0,0,0,0.55)",
    borderRadius: 8,
    paddingHorizontal: 12,
    paddingVertical: 8,
    overflow: "hidden",
  },
  scannerFrame: {
    width: 230,
    height: 230,
    borderRadius: 16,
    borderWidth: 3,
    borderColor: "rgba(255,255,255,0.85)",
  },
  scannerClose: {
    backgroundColor: "rgba(0,0,0,0.55)",
    borderRadius: 24,
    paddingHorizontal: 28,
    paddingVertical: 12,
  },
  scannerCloseText: { color: "#fff", fontSize: 16, fontWeight: "600" },
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
