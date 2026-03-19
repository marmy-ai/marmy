import React from "react";
import { View, Text, TouchableOpacity, StyleSheet } from "react-native";
import { theme } from "../theme";

interface RetroComputerProps {
  name: string;
  onPress: () => void;
  onLongPress: () => void;
}

/** Round glasses with eyes — matches the app icon */
function MarmyGlasses({ size = 24 }: { size?: number }) {
  const eyeSize = size * 0.4;
  const pupilSize = eyeSize * 0.55;
  return (
    <View style={glassesStyles.row}>
      {/* Left lens */}
      <View style={[glassesStyles.lens, { width: size, height: size, borderRadius: size / 2 }]}>
        <View style={[glassesStyles.eye, { width: eyeSize, height: eyeSize, borderRadius: eyeSize / 2 }]}>
          <View style={[glassesStyles.pupil, { width: pupilSize, height: pupilSize, borderRadius: pupilSize / 2 }]} />
        </View>
      </View>
      {/* Bridge */}
      <View style={[glassesStyles.bridge, { width: size * 0.3 }]} />
      {/* Right lens */}
      <View style={[glassesStyles.lens, { width: size, height: size, borderRadius: size / 2 }]}>
        <View style={[glassesStyles.eye, { width: eyeSize, height: eyeSize, borderRadius: eyeSize / 2 }]}>
          <View style={[glassesStyles.pupil, { width: pupilSize, height: pupilSize, borderRadius: pupilSize / 2 }]} />
        </View>
      </View>
    </View>
  );
}

const glassesStyles = StyleSheet.create({
  row: { flexDirection: "row", alignItems: "center", justifyContent: "center" },
  lens: {
    borderWidth: 2.5,
    borderColor: theme.primary,
    alignItems: "center",
    justifyContent: "center",
  },
  bridge: {
    height: 2.5,
    backgroundColor: theme.primary,
  },
  eye: {
    backgroundColor: "#fff",
    alignItems: "center",
    justifyContent: "center",
  },
  pupil: {
    backgroundColor: "#1a1a2e",
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
          <MarmyGlasses size={26} />
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
    maxWidth: "50%",
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
