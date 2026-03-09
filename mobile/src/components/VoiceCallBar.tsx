import React, { useRef, useEffect, useState } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  Animated,
  PanResponder,
} from "react-native";
import * as Haptics from "expo-haptics";
import type { VoiceState } from "../services/voiceSession";

interface VoiceCallBarProps {
  state: VoiceState;
  onEnd: () => void;
  onMicOn: () => void;
  onMicOff: () => void;
}

const STATE_CONFIG: Record<VoiceState, { color: string; text: string }> = {
  idle: { color: "#888", text: "Idle" },
  connecting: { color: "#888", text: "Connecting..." },
  listening: { color: "#4ade80", text: "Ready" },
  model_speaking: { color: "#7c3aed", text: "Speaking..." },
  error: { color: "#ef4444", text: "Error" },
};

function formatDuration(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${s.toString().padStart(2, "0")}`;
}

export default function VoiceCallBar({ state, onEnd, onMicOn, onMicOff }: VoiceCallBarProps) {
  const pulseAnim = useRef(new Animated.Value(1)).current;
  const [micActive, setMicActive] = useState(false);
  const [elapsed, setElapsed] = useState(0);
  const [timerRunning, setTimerRunning] = useState(false);

  // Dragging — applied to entire overlay, buttons use onStartShouldSetResponder to block
  const pan = useRef(new Animated.ValueXY()).current;
  const panResponder = useRef(
    PanResponder.create({
      onStartShouldSetPanResponder: () => false,
      onMoveShouldSetPanResponder: (_, g) =>
        Math.abs(g.dx) > 8 || Math.abs(g.dy) > 8,
      onPanResponderMove: Animated.event(
        [null, { dx: pan.x, dy: pan.y }],
        { useNativeDriver: false }
      ),
      onPanResponderRelease: () => {
        pan.extractOffset();
      },
    })
  ).current;

  // Pulse animation when model is speaking
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

  // Start timer once connected
  useEffect(() => {
    if (!timerRunning && (state === "listening" || state === "model_speaking")) {
      setTimerRunning(true);
    }
  }, [state, timerRunning]);

  useEffect(() => {
    if (!timerRunning) return;
    const interval = setInterval(() => {
      setElapsed((prev) => prev + 1);
    }, 1000);
    return () => clearInterval(interval);
  }, [timerRunning]);

  const { color, text } = STATE_CONFIG[state];
  const canTalk = state === "listening" || state === "model_speaking";

  return (
    <Animated.View
      style={[styles.overlay, { transform: pan.getTranslateTransform() }]}
      {...panResponder.panHandlers}
    >
      {/* Drag indicator */}
      <View style={styles.dragHandle}>
        <View style={styles.dragIndicator} />
      </View>

      {/* Timer + status */}
      <View style={styles.statusRow}>
        <Text style={styles.timer}>{formatDuration(elapsed)}</Text>
        <View style={styles.statusRight}>
          <Animated.View
            style={[styles.dot, { backgroundColor: color, opacity: pulseAnim }]}
          />
          <Text style={[styles.statusText, { color }]}>
            {micActive ? "Recording..." : text}
          </Text>
        </View>
      </View>

      {/* Mute/Unmute toggle */}
      <TouchableOpacity
        style={[
          styles.micButton,
          micActive && styles.micButtonActive,
          !canTalk && styles.micButtonDisabled,
        ]}
        disabled={!canTalk}
        activeOpacity={0.7}
        onPress={() => {
          if (micActive) {
            setMicActive(false);
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            onMicOff();
          } else {
            setMicActive(true);
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
            onMicOn();
          }
        }}
      >
        <Text style={[styles.micText, micActive && styles.micTextActive]}>
          {micActive ? "Mute" : "Unmute"}
        </Text>
      </TouchableOpacity>

      {/* End call */}
      <TouchableOpacity
        style={styles.endButton}
        activeOpacity={0.7}
        onPress={() => {
          Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
          onEnd();
        }}
      >
        <Text style={styles.endButtonText}>End</Text>
      </TouchableOpacity>
    </Animated.View>
  );
}

const styles = StyleSheet.create({
  overlay: {
    width: 180,
    backgroundColor: "#161625",
    borderRadius: 20,
    borderWidth: 1,
    borderColor: "#2a2a3e",
    paddingBottom: 14,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 6 },
    shadowOpacity: 0.6,
    shadowRadius: 16,
    elevation: 12,
  },
  dragHandle: {
    alignItems: "center",
    paddingTop: 10,
    paddingBottom: 6,
  },
  dragIndicator: {
    width: 32,
    height: 4,
    borderRadius: 2,
    backgroundColor: "#444",
  },
  statusRow: {
    flexDirection: "row",
    alignItems: "center",
    justifyContent: "space-between",
    paddingHorizontal: 16,
    marginBottom: 14,
  },
  timer: {
    color: "#e0e0e0",
    fontSize: 18,
    fontWeight: "700",
    fontFamily: "monospace",
  },
  statusRight: {
    flexDirection: "row",
    alignItems: "center",
    gap: 5,
  },
  dot: {
    width: 8,
    height: 8,
    borderRadius: 4,
  },
  statusText: {
    fontSize: 11,
    fontWeight: "600",
    fontFamily: "monospace",
  },
  micButton: {
    marginHorizontal: 14,
    height: 56,
    borderRadius: 28,
    backgroundColor: "#2a2a3e",
    borderWidth: 2,
    borderColor: "#4ade80",
    alignItems: "center",
    justifyContent: "center",
    marginBottom: 10,
  },
  micButtonActive: {
    backgroundColor: "#4ade80",
    borderColor: "#4ade80",
  },
  micButtonDisabled: {
    borderColor: "#444",
    opacity: 0.4,
  },
  micText: {
    color: "#4ade80",
    fontSize: 15,
    fontWeight: "700",
  },
  micTextActive: {
    color: "#0f0f1a",
  },
  endButton: {
    marginHorizontal: 14,
    height: 36,
    borderRadius: 18,
    backgroundColor: "#ef4444",
    alignItems: "center",
    justifyContent: "center",
  },
  endButtonText: {
    color: "#fff",
    fontSize: 13,
    fontWeight: "700",
  },
});
