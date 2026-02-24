import { create } from "zustand";

interface SessionState {
  activePaneId: string | null;
  activeSessionId: string | null;
  viewMode: "raw" | "rich";

  setActivePane: (paneId: string) => void;
  setActiveSession: (sessionId: string) => void;
  setViewMode: (mode: "raw" | "rich") => void;
}

export const useSessionStore = create<SessionState>((set) => ({
  activePaneId: null,
  activeSessionId: null,
  viewMode: "raw",

  setActivePane: (paneId) => set({ activePaneId: paneId }),
  setActiveSession: (sessionId) => set({ activeSessionId: sessionId }),
  setViewMode: (mode) => set({ viewMode: mode }),
}));
