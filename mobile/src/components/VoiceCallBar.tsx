import React, { useRef, useEffect, useState } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  Pressable,
  StyleSheet,
  Animated,
} from "react-native";
import * as Haptics from "expo-haptics";
import type { VoiceState } from "../services/voiceSession";

interface VoiceCallBarProps {
  state: VoiceState;
  onEnd: () => void;
  onPttStart: () => void;
  onPttEnd: () => void;
}

const STATE_CONFIG: Record<VoiceState, { color: string; text: string }> = {
  idle: { color: "#888", text: "Idle" },
  connecting: { color: "#888", text: "Connecting..." },
  listening: { color: "#4ade80", text: "Ready" },
  model_speaking: { color: "#7c3aed", text: "Speaking..." },
  error: { color: "#ef4444", text: "Error" },
};

export default function VoiceCallBar({ state, onEnd, onPttStart, onPttEnd }: VoiceCallBarProps) {
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const [holding, setHolding] = useState(false);

  useEffect(() => {
    if (state === "model_speaking") {
      Animated.loop(
        Animated.sequence([
          Animated.timing(pulseAnim, { toValue: 0.3, duration: 800, useNativeDriver: true }),
          Animated.timing(pulseAnim, { toValue: 1, duration: 800, useNativeDriver: true }),
        ])
      ).start();
    } else {
      pulseAnim.setValue(1);
    }
  }, [state]);

  const { color, text } = STATE_CONFIG[state];
  const canTalk = state === "listening" || state === "model_speaking";

  return (
    <View style={styles.container}>
      <View style={styles.statusRow}>
        <Animated.View
          style={[styles.dot, { backgroundColor: color, opacity: pulseAnim }]}
        />
        <Text style={[styles.statusText, { color }]}>
          {holding ? "Recording..." : text}
        </Text>
      </View>

      <View style={styles.buttons}>
        {canTalk && (
          <Pressable
            style={[styles.pttButton, holding && styles.pttButtonActive]}
            onPressIn={() => {
              setHolding(true);
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
              onPttStart();
            }}
            onPressOut={() => {
              setHolding(false);
              Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
              onPttEnd();
            }}
          >
            <Text style={[styles.pttText, holding && styles.pttTextActive]}>
              Hold to Talk
            </Text>
          </Pressable>
        )}

        <TouchableOpacity
          style={styles.endButton}
          onPress={() => {
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
            onEnd();
          }}
        >
          <Text style={styles.endButtonText}>End</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    height: 44,
    borderTopWidth: 1,
    borderTopColor: "#2a2a3e",
    backgroundColor: "#1a1a2e",
    paddingHorizontal: 12,
  },
  statusRow: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  dot: {
    width: 10,
    height: 10,
    borderRadius: 5,
  },
  statusText: {
    fontSize: 13,
    fontWeight: "600",
    fontFamily: "monospace",
  },
  buttons: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
  },
  pttButton: {
    backgroundColor: "#2a2a3e",
    paddingHorizontal: 14,
    paddingVertical: 6,
    borderRadius: 8,
    borderWidth: 1,
    borderColor: "#4ade80",
  },
  pttButtonActive: {
    backgroundColor: "#4ade80",
  },
  pttText: {
    color: "#4ade80",
    fontSize: 13,
    fontWeight: "700",
  },
  pttTextActive: {
    color: "#0f0f1a",
  },
  endButton: {
    backgroundColor: "#ef4444",
    paddingHorizontal: 12,
    paddingVertical: 6,
    borderRadius: 8,
  },
  endButtonText: {
    color: "#fff",
    fontSize: 13,
    fontWeight: "700",
  },
});
