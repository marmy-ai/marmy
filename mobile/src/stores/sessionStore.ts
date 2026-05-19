import { create } from "zustand";

export type AgentMode = "claude" | "codex" | "terminal";

interface SessionState {
  activePaneId: string | null;
  activeSessionId: string | null;
  activeSessionName: string | null;
  activeAgentMode: AgentMode;
  viewMode: "raw" | "rich";
  notifyOnDone: boolean;

  setActivePane: (paneId: string) => void;
  setActiveSession: (sessionId: string) => void;
  setActiveSessionName: (name: string) => void;
  setActiveAgentMode: (mode: AgentMode) => void;
  setViewMode: (mode: "raw" | "rich") => void;
  setNotifyOnDone: (enabled: boolean) => void;
}

export const useSessionStore = create<SessionState>((set) => ({
  activePaneId: null,
  activeSessionId: null,
  activeSessionName: null,
  activeAgentMode: "claude",
  viewMode: "raw",
  notifyOnDone: true,

  setActivePane: (paneId) => set({ activePaneId: paneId }),
  setActiveSession: (sessionId) => set({ activeSessionId: sessionId }),
  setActiveSessionName: (name) => set({ activeSessionName: name }),
  setActiveAgentMode: (mode) => set({ activeAgentMode: mode }),
  setViewMode: (mode) => set({ viewMode: mode }),
  setNotifyOnDone: (enabled) => set({ notifyOnDone: enabled }),
}));
