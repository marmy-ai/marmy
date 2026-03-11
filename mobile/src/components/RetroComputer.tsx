import React from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import { theme } from "../theme";

interface RetroComputerProps {
  name: string;
  onPress: () => void;
  onLongPress: () => void;
}

/** Small glasses icon drawn with Views */
function MarmyGlasses() {
  return (
    <View style={glassesStyles.row}>
      <View style={glassesStyles.lens} />
      <View style={glassesStyles.bridge} />
      <View style={glassesStyles.lens} />
    </View>
  );
}

const glassesStyles = StyleSheet.create({
  row: { flexDirection: "row", alignItems: "center", justifyContent: "center" },
  lens: {
    width: 18,
    height: 14,
    borderRadius: 4,
    borderWidth: 2.5,
    borderColor: theme.primary,
  },
  bridge: {
    width: 6,
    height: 2.5,
    backgroundColor: theme.primary,
  },
});

export default function RetroComputer({
  name,
  onPress,
  onLongPress,
}: RetroComputerProps) {
  return (
    <TouchableOpacity
      style={styles.wrapper}
      onPress={onPress}
      onLongPress={onLongPress}
      activeOpacity={0.7}
    >
      {/* Monitor */}
      <View style={styles.monitor}>
        {/* Screen — shows logo glasses + terminal cursor */}
        <View style={styles.screen}>
          <MarmyGlasses />
          <Text style={styles.cursor}>{">_"}</Text>
        </View>
        {/* Machine name below screen */}
        <Text style={styles.machineName} numberOfLines={1}>
          {name}
        </Text>
      </View>

      {/* Stand */}
      <View style={styles.standColumn}>
        <View style={styles.standNeck} />
      </View>

      {/* Keyboard */}
      <View style={styles.keyboard}>
        <View style={styles.keyRow}>
          {[0, 1, 2, 3, 4, 5, 6, 7].map((i) => (
            <View key={i} style={styles.keyDot} />
          ))}
        </View>
        <View style={styles.keyRow}>
          {[0, 1, 2, 3, 4, 5, 6].map((i) => (
            <View key={i} style={styles.keyDot} />
          ))}
        </View>
      </View>
    </TouchableOpacity>
  );
}

const styles = StyleSheet.create({
  wrapper: {
    flex: 1,
    margin: 6,
    alignItems: "center",
  },
  monitor: {
    width: "100%",
    backgroundColor: theme.bgCard,
    borderRadius: 8,
    borderWidth: 3,
    borderColor: theme.primary,
    padding: 8,
    paddingBottom: 6,
  },
  screen: {
    backgroundColor: "#0a0a14",
    borderRadius: 4,
    padding: 16,
    minHeight: 70,
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
  },
  cursor: {
    color: theme.secondary,
    fontSize: 14,
    fontWeight: "700",
    fontFamily: "monospace",
  },
  machineName: {
    color: theme.secondary,
    fontSize: 10,
    fontWeight: "800",
    fontFamily: "monospace",
    textAlign: "center",
    letterSpacing: 1,
    marginTop: 6,
  },
  standColumn: {
    alignItems: "center",
  },
  standNeck: {
    width: 16,
    height: 8,
    backgroundColor: theme.border,
    borderBottomLeftRadius: 2,
    borderBottomRightRadius: 2,
  },
  keyboard: {
    width: "80%",
    backgroundColor: theme.border,
    borderRadius: 3,
    paddingVertical: 4,
    paddingHorizontal: 6,
  },
  keyRow: {
    flexDirection: "row",
    justifyContent: "space-between",
    marginVertical: 1,
  },
  keyDot: {
    width: 6,
    height: 4,
    borderRadius: 1,
    backgroundColor: theme.borderLight,
  },
});
