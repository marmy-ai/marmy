import React, { useRef, useEffect } from "react";
import {
  View,
  Text,
  TouchableOpacity,
  ScrollView,
  StyleSheet,
  Animated,
} from "react-native";
import * as Haptics from "expo-haptics";
import { theme } from "../theme";

interface SttBarProps {
  transcript: string;
  onDone: () => void;
  onCancel: () => void;
}

export default function SttBar({ transcript, onDone, onCancel }: SttBarProps) {
  const pulseAnim = useRef(new Animated.Value(1)).current;

  useEffect(() => {
    const anim = Animated.loop(
      Animated.sequence([
        Animated.timing(pulseAnim, { toValue: 0.2, duration: 600, useNativeDriver: true }),
        Animated.timing(pulseAnim, { toValue: 1, duration: 600, useNativeDriver: true }),
      ])
    );
    anim.start();
    return () => anim.stop();
  }, []);

  const hasText = transcript.trim().length > 0;

  return (
    <View style={styles.container}>
      <View style={styles.header}>
        <Animated.View style={[styles.dot, { opacity: pulseAnim }]} />
        <Text style={styles.headerText}>Listening...</Text>
      </View>

      <ScrollView
        style={styles.transcriptScroll}
        contentContainerStyle={styles.transcriptContent}
      >
        <Text style={[styles.transcript, !hasText && styles.placeholder]}>
          {hasText ? transcript : "Speak now…"}
        </Text>
      </ScrollView>

      <View style={styles.buttons}>
        <TouchableOpacity
          style={styles.cancelBtn}
          activeOpacity={0.7}
          onPress={() => {
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
            onCancel();
          }}
        >
          <Text style={styles.cancelText}>Cancel</Text>
        </TouchableOpacity>

        <TouchableOpacity
          style={[styles.doneBtn, !hasText && styles.doneBtnDisabled]}
          activeOpacity={0.7}
          onPress={() => {
            if (!hasText) return;
            Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
            onDone();
          }}
        >
          <Text style={styles.doneText}>Done</Text>
        </TouchableOpacity>
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    width: 260,
    backgroundColor: "#161625",
    borderRadius: 20,
    borderWidth: 1,
    borderColor: "#2a2a3e",
    paddingVertical: 14,
    paddingHorizontal: 14,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 6 },
    shadowOpacity: 0.6,
    shadowRadius: 16,
    elevation: 12,
  },
  header: {
    flexDirection: "row",
    alignItems: "center",
    gap: 8,
    marginBottom: 10,
  },
  dot: {
    width: 10,
    height: 10,
    borderRadius: 5,
    backgroundColor: "#ef4444",
  },
  headerText: {
    color: "#ef4444",
    fontSize: 12,
    fontWeight: "700",
    fontFamily: "monospace",
  },
  transcriptScroll: {
    maxHeight: 100,
    marginBottom: 12,
  },
  transcriptContent: {
    flexGrow: 1,
  },
  transcript: {
    color: "#e0e0e0",
    fontSize: 14,
    fontFamily: "monospace",
    lineHeight: 20,
  },
  placeholder: {
    color: "#555",
    fontStyle: "italic",
  },
  buttons: {
    flexDirection: "row",
    gap: 8,
  },
  cancelBtn: {
    flex: 1,
    height: 36,
    borderRadius: 18,
    backgroundColor: "#2a2a3e",
    alignItems: "center",
    justifyContent: "center",
  },
  cancelText: {
    color: "#888",
    fontSize: 13,
    fontWeight: "700",
  },
  doneBtn: {
    flex: 2,
    height: 36,
    borderRadius: 18,
    backgroundColor: "#4ade80",
    alignItems: "center",
    justifyContent: "center",
  },
  doneBtnDisabled: {
    backgroundColor: "#2a2a3e",
  },
  doneText: {
    color: "#0f0f1a",
    fontSize: 13,
    fontWeight: "700",
  },
});
