import React, { useCallback, useMemo, useRef, useState } from "react";
import {
  StyleSheet,
  Text,
  TouchableOpacity,
  View,
} from "react-native";
import type {
  GestureResponderEvent,
  NativeSyntheticEvent,
  TextLayoutEventData,
} from "react-native";
import * as Clipboard from "expo-clipboard";
import * as Haptics from "expo-haptics";
import { Ionicons } from "@expo/vector-icons";
import { theme } from "../theme";

// Custom text selection for the terminal. RN's New Architecture renders
// <Text selectable> without partial selection (long-press can only copy the
// whole block — see commit 4fc36a7), so we do it ourselves: the terminal is a
// monospace grid, and onTextLayout reports every *visual* line with its text
// and rect. Long-press anchors a word, dragging extends it, and a floating
// bar offers Copy / Select All / Done. A trailing "\n" on a layout line
// distinguishes a real line end from a soft wrap, so copied text joins
// wrapped segments back together seamlessly.

interface VisualLine {
  clean: string; // line text without the trailing newline
  hard: boolean; // true when the line ends in "\n" (real break, not a wrap)
  x: number;
  y: number;
  width: number;
  height: number;
}

interface Point {
  row: number;
  col: number;
}

const LONG_PRESS_MS = 450;
const MOVE_SLOP = 10;
const FALLBACK_CHAR_WIDTH = 6.63; // Menlo at fontSize 11
const SELECTION_BG = "rgba(232, 97, 60, 0.30)"; // theme.primary @ 30%

function stripAnsi(raw: string): string {
  return raw
    .replace(/\x1b\[[0-9;?]*[a-zA-Z]/g, "")
    .replace(/\x1b\][^\x07]*\x07/g, "");
}

export function useTerminalSelection(content: string) {
  const [active, setActive] = useState(false);
  const [frozen, setFrozen] = useState<string | null>(null);
  const [anchor, setAnchor] = useState<Point | null>(null);
  const [focus, setFocus] = useState<Point | null>(null);

  const linesRef = useRef<VisualLine[]>([]);
  const contentRef = useRef(content);
  contentRef.current = content;

  const touchRef = useRef({
    x: 0,
    y: 0,
    startX: 0,
    startY: 0,
    moved: false,
    timer: null as ReturnType<typeof setTimeout> | null,
    activatedByThisTouch: false,
  });

  const onTextLayout = useCallback(
    (e: NativeSyntheticEvent<TextLayoutEventData>) => {
      // While a selection is up the content is frozen, so the last layout
      // already matches what's on screen — don't let a stray event drift it.
      if (active) return;
      linesRef.current = e.nativeEvent.lines.map((l) => {
        const hard = l.text.endsWith("\n");
        return {
          clean: hard ? l.text.slice(0, -1) : l.text,
          hard,
          x: l.x,
          y: l.y,
          width: l.width,
          height: l.height,
        };
      });
    },
    [active]
  );

  const charWidth = useCallback((line: VisualLine): number => {
    // Layout width excludes trailing whitespace, so divide by visible chars.
    const visible = line.clean.replace(/\s+$/, "").length;
    if (visible > 0 && line.width > 0) return line.width / visible;
    let best: VisualLine | null = null;
    for (const l of linesRef.current) {
      const len = l.clean.replace(/\s+$/, "").length;
      if (len > 3 && (!best || len > best.clean.length)) best = l;
    }
    if (best) return best.width / best.clean.replace(/\s+$/, "").length;
    return FALLBACK_CHAR_WIDTH;
  }, []);

  const pointAt = useCallback(
    (x: number, y: number): Point => {
      const lines = linesRef.current;
      if (lines.length === 0) return { row: 0, col: 0 };
      let row = lines.length - 1;
      for (let i = 0; i < lines.length; i++) {
        if (y < lines[i].y + lines[i].height) {
          row = i;
          break;
        }
      }
      const line = lines[row];
      const col = Math.round((x - line.x) / charWidth(line));
      return { row, col: Math.max(0, Math.min(col, line.clean.length)) };
    },
    [charWidth]
  );

  // Word under the touch (non-whitespace run); whitespace selects the line.
  const wordRangeAt = useCallback((row: number, x: number): [Point, Point] => {
    const line = linesRef.current[row];
    const text = line?.clean ?? "";
    if (!text.trim()) return [{ row, col: 0 }, { row, col: text.length }];
    const cw = charWidth(line);
    const i = Math.max(
      0,
      Math.min(Math.floor((x - line.x) / cw), text.length - 1)
    );
    if (/\s/.test(text[i])) return [{ row, col: 0 }, { row, col: text.length }];
    let a = i;
    let b = i;
    while (a > 0 && !/\s/.test(text[a - 1])) a--;
    while (b < text.length - 1 && !/\s/.test(text[b + 1])) b++;
    return [{ row, col: a }, { row, col: b + 1 }];
  }, [charWidth]);

  const ordered = useCallback((): [Point, Point] | null => {
    if (!anchor || !focus) return null;
    if (
      focus.row < anchor.row ||
      (focus.row === anchor.row && focus.col < anchor.col)
    ) {
      return [focus, anchor];
    }
    return [anchor, focus];
  }, [anchor, focus]);

  const extractText = useCallback((): string => {
    const range = ordered();
    const lines = linesRef.current;
    if (!range || lines.length === 0) {
      // No layout info (shouldn't happen) — fall back to everything.
      return stripAnsi(frozen ?? contentRef.current);
    }
    const [s, e] = range;
    let out = "";
    for (let r = s.row; r <= e.row && r < lines.length; r++) {
      const line = lines[r];
      const from = r === s.row ? s.col : 0;
      const to = r === e.row ? e.col : line.clean.length;
      let seg = line.clean.slice(from, to);
      // Trailing pad spaces from tmux's fixed-width capture aren't content.
      if (line.hard && to === line.clean.length) seg = seg.replace(/[ \t]+$/, "");
      out += seg;
      if (r < e.row && line.hard) out += "\n";
    }
    return out;
  }, [ordered, frozen]);

  const deactivate = useCallback(() => {
    setActive(false);
    setFrozen(null);
    setAnchor(null);
    setFocus(null);
  }, []);

  const selectAll = useCallback(() => {
    const lines = linesRef.current;
    if (lines.length === 0) return;
    const last = lines.length - 1;
    setAnchor({ row: 0, col: 0 });
    setFocus({ row: last, col: lines[last].clean.length });
    Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Light);
  }, []);

  const copySelection = useCallback(async () => {
    const text = extractText();
    if (text.length > 0) {
      await Clipboard.setStringAsync(text);
      Haptics.notificationAsync(Haptics.NotificationFeedbackType.Success);
    }
    deactivate();
  }, [extractText, deactivate]);

  // --- Touch handling (plain touch events; the ScrollView keeps scrolling
  // normally while inactive because we never claim the responder) ---

  const onTouchStart = useCallback(
    (e: GestureResponderEvent) => {
      const { locationX, locationY } = e.nativeEvent;
      const t = touchRef.current;
      t.x = locationX;
      t.y = locationY;
      t.startX = locationX;
      t.startY = locationY;
      t.moved = false;
      t.activatedByThisTouch = false;
      if (t.timer) clearTimeout(t.timer);
      if (!active) {
        t.timer = setTimeout(() => {
          t.timer = null;
          if (t.moved) return;
          const p = pointAt(t.x, t.y);
          const [a, f] = wordRangeAt(p.row, t.x);
          t.activatedByThisTouch = true;
          setFrozen(contentRef.current);
          setAnchor(a);
          setFocus(f);
          setActive(true);
          Haptics.impactAsync(Haptics.ImpactFeedbackStyle.Medium);
        }, LONG_PRESS_MS);
      }
    },
    [active, pointAt, wordRangeAt]
  );

  const onTouchMove = useCallback(
    (e: GestureResponderEvent) => {
      const { locationX, locationY } = e.nativeEvent;
      const t = touchRef.current;
      t.x = locationX;
      t.y = locationY;
      if (
        Math.abs(locationX - t.startX) > MOVE_SLOP ||
        Math.abs(locationY - t.startY) > MOVE_SLOP
      ) {
        t.moved = true;
        if (t.timer) {
          clearTimeout(t.timer);
          t.timer = null;
        }
      }
      if (active && t.moved) {
        setFocus(pointAt(locationX, locationY));
      }
    },
    [active, pointAt]
  );

  const onTouchEnd = useCallback(() => {
    const t = touchRef.current;
    if (t.timer) {
      clearTimeout(t.timer);
      t.timer = null;
    }
    if (active && !t.activatedByThisTouch && !t.moved) {
      // Plain tap while a selection is up dismisses it.
      deactivate();
    }
    t.activatedByThisTouch = false;
  }, [active, deactivate]);

  // --- Overlay + toolbar ---

  const highlightOverlay = useMemo(() => {
    if (!active || !anchor || !focus) return null;
    const range = ordered();
    if (!range) return null;
    const [s, e] = range;
    const lines = linesRef.current;
    const rects: { x: number; y: number; w: number; h: number }[] = [];
    for (let r = s.row; r <= e.row && r < lines.length; r++) {
      const line = lines[r];
      const cw = charWidth(line);
      const from = r === s.row ? s.col : 0;
      const to = r === e.row ? e.col : line.clean.length;
      rects.push({
        x: line.x + from * cw,
        y: line.y,
        w: Math.max((to - from) * cw, 3),
        h: line.height,
      });
    }
    return (
      <View pointerEvents="none" style={StyleSheet.absoluteFill}>
        {rects.map((rc, i) => (
          <View
            key={i}
            style={{
              position: "absolute",
              left: rc.x,
              top: rc.y,
              width: rc.w,
              height: rc.h,
              backgroundColor: SELECTION_BG,
              borderRadius: 2,
            }}
          />
        ))}
      </View>
    );
  }, [active, anchor, focus, ordered, charWidth]);

  const toolbar = active ? (
    <View style={styles.bar} pointerEvents="box-none">
      <TouchableOpacity
        style={styles.barBtn}
        onPress={copySelection}
        accessibilityRole="button"
        accessibilityLabel="Copy selection"
      >
        <Ionicons name="copy-outline" size={16} color="#fff" />
        <Text style={styles.barBtnText}>Copy</Text>
      </TouchableOpacity>
      <View style={styles.barDivider} />
      <TouchableOpacity
        style={styles.barBtn}
        onPress={selectAll}
        accessibilityRole="button"
        accessibilityLabel="Select all terminal text"
      >
        <Text style={styles.barBtnText}>Select All</Text>
      </TouchableOpacity>
      <View style={styles.barDivider} />
      <TouchableOpacity
        style={styles.barBtn}
        onPress={deactivate}
        accessibilityRole="button"
        accessibilityLabel="Dismiss selection"
      >
        <Ionicons name="close" size={16} color="#fff" />
      </TouchableOpacity>
    </View>
  ) : null;

  return {
    active,
    displayContent: frozen ?? content,
    onTextLayout,
    touchHandlers: { onTouchStart, onTouchMove, onTouchEnd },
    highlightOverlay,
    toolbar,
  };
}

const styles = StyleSheet.create({
  bar: {
    position: "absolute",
    top: 8,
    alignSelf: "center",
    flexDirection: "row",
    alignItems: "center",
    backgroundColor: theme.bgElevated,
    borderColor: theme.border,
    borderWidth: 1,
    borderRadius: 20,
    paddingHorizontal: 6,
    paddingVertical: 4,
    shadowColor: "#000",
    shadowOffset: { width: 0, height: 2 },
    shadowOpacity: 0.35,
    shadowRadius: 6,
    elevation: 6,
  },
  barBtn: {
    flexDirection: "row",
    alignItems: "center",
    gap: 5,
    paddingHorizontal: 12,
    paddingVertical: 6,
  },
  barBtnText: { color: "#fff", fontSize: 13, fontWeight: "600" },
  barDivider: {
    width: 1,
    height: 18,
    backgroundColor: theme.border,
  },
});
