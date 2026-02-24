import { create } from "zustand";
import type { Machine, TmuxTopology } from "../types";
import { MarmyApi } from "../services/api";
import { MarmySocket } from "../services/websocket";

interface ConnectionState {
  machines: Machine[];
  activeMachine: Machine | null;
  topology: TmuxTopology | null;
  api: MarmyApi | null;
  socket: MarmySocket | null;
  connected: boolean;

  addMachine: (machine: Omit<Machine, "id" | "online">) => void;
  removeMachine: (id: string) => void;
  connectToMachine: (machine: Machine) => Promise<void>;
  disconnect: () => void;
  setTopology: (topology: TmuxTopology) => void;
  setConnected: (connected: boolean) => void;
}

export const useConnectionStore = create<ConnectionState>((set, get) => ({
  machines: [],
  activeMachine: null,
  topology: null,
  api: null,
  socket: null,
  connected: false,

  addMachine: (machine) => {
    const newMachine: Machine = {
      ...machine,
      id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
      online: false,
    };
    set((state) => ({ machines: [...state.machines, newMachine] }));
  },

  removeMachine: (id) => {
    set((state) => ({
      machines: state.machines.filter((m) => m.id !== id),
    }));
  },

  connectToMachine: async (machine) => {
    const { socket: oldSocket } = get();
    if (oldSocket) {
      oldSocket.disconnect();
    }

    const api = new MarmyApi(machine.address, machine.token);
    const wsUrl = api.getWsUrl();
    const socket = new MarmySocket(wsUrl);

    // Listen for topology updates
    socket.onMessage((msg) => {
      if (msg.type === "topology") {
        get().setTopology({
          sessions: msg.sessions,
          windows: msg.windows,
          panes: msg.panes,
        });
      }
    });

    socket.connect();

    set({
      activeMachine: { ...machine, online: true },
      api,
      socket,
      connected: true,
    });

    // Fetch initial topology
    try {
      const topology = await api.getSessions();
      set({ topology });
    } catch {
      // WebSocket will provide topology on connect
    }
  },

  disconnect: () => {
    const { socket } = get();
    if (socket) {
      socket.disconnect();
    }
    set({
      activeMachine: null,
      api: null,
      socket: null,
      topology: null,
      connected: false,
    });
  },

  setTopology: (topology) => set({ topology }),
  setConnected: (connected) => set({ connected }),
}));
