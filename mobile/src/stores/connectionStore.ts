import { create } from "zustand";
import * as SecureStore from "expo-secure-store";
import type { Machine, TmuxTopology } from "../types";
import { MarmyApi } from "../services/api";
import { MarmySocket } from "../services/websocket";
import { registerForPushNotifications } from "../services/notifications";

const MACHINES_KEY = "marmy_machines";

async function loadMachines(): Promise<Machine[]> {
  try {
    const raw = await SecureStore.getItemAsync(MACHINES_KEY);
    if (raw) return JSON.parse(raw);
  } catch {}
  return [];
}

async function saveMachines(machines: Machine[]): Promise<void> {
  try {
    await SecureStore.setItemAsync(MACHINES_KEY, JSON.stringify(machines));
  } catch {}
}

interface ConnectionState {
  machines: Machine[];
  activeMachine: Machine | null;
  topology: TmuxTopology | null;
  api: MarmyApi | null;
  socket: MarmySocket | null;
  connected: boolean;
  hydrated: boolean;

  hydrate: () => Promise<void>;
  addMachine: (machine: Omit<Machine, "id" | "online">) => void;
  updateMachine: (id: string, updates: Partial<Pick<Machine, "name" | "address" | "token">>) => void;
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
  hydrated: false,

  hydrate: async () => {
    const machines = await loadMachines();
    set({ machines, hydrated: true });
  },

  addMachine: (machine) => {
    const newMachine: Machine = {
      ...machine,
      id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6),
      online: false,
    };
    const machines = [...get().machines, newMachine];
    set({ machines });
    saveMachines(machines);
  },

  updateMachine: (id, updates) => {
    const machines = get().machines.map((m) =>
      m.id === id ? { ...m, ...updates } : m
    );
    set({ machines });
    saveMachines(machines);
  },

  removeMachine: (id) => {
    const machines = get().machines.filter((m) => m.id !== id);
    set({ machines });
    saveMachines(machines);
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

    // Register for push notifications (fire and forget)
    registerForPushNotifications(api).catch(() => {});
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
