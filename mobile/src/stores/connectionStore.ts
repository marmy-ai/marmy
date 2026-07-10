import { create } from "zustand";
import * as SecureStore from "expo-secure-store";
import type { Machine, TmuxTopology } from "../types";
import { MarmyApi } from "../services/api";
import { MarmySocket } from "../services/websocket";
import { registerForPushNotifications } from "../services/notifications";

const MACHINES_KEY = "marmy_machines";

// Monotonic connect token. connectToMachine suspends on network probes, so
// overlapping calls (double-tap, switch machines mid-connect) must be able to
// tell they've been superseded — otherwise the loser's socket leaks and its
// later set() clobbers the winner's connection.
let connectSeq = 0;

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
  updateMachine: (id: string, updates: Partial<Pick<Machine, "name" | "address" | "addresses" | "token">>) => void;
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
    const seq = ++connectSeq;
    const { socket: oldSocket } = get();
    if (oldSocket) {
      oldSocket.disconnect();
    }

    // Pick the best address. Order: last-known-good first (it usually still
    // works, so reconnects are instant), then the QR candidate list
    // (Tailscale before LAN). All probes launch concurrently; the first
    // candidate in priority order that answered wins, so the worst case is
    // one probe timeout, not one per candidate.
    let address = machine.address;
    const candidates = [
      ...new Set([machine.address, ...(machine.addresses ?? [])]),
    ];
    if (candidates.length > 1) {
      const probes = candidates.map((c) =>
        MarmyApi.probeAddress(c, machine.token)
      );
      let reachable: string | null = null;
      for (let i = 0; i < candidates.length; i++) {
        if (await probes[i]) {
          reachable = candidates[i];
          break;
        }
      }
      if (seq !== connectSeq) return; // superseded by a newer connect
      if (!reachable) {
        throw new Error(`No address is reachable (tried ${candidates.join(", ")})`);
      }
      address = reachable;
      if (address !== machine.address) {
        const machines = get().machines.map((m) =>
          m.id === machine.id ? { ...m, address } : m
        );
        set({ machines });
        saveMachines(machines);
      }
    }
    if (seq !== connectSeq) return;

    const api = new MarmyApi(address, machine.token);
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
      activeMachine: { ...machine, address, online: true },
      api,
      socket,
      connected: true,
    });

    // Fetch initial topology
    try {
      const topology = await api.getSessions();
      if (seq === connectSeq) set({ topology });
    } catch {
      // WebSocket will provide topology on connect
    }

    // Register for push notifications (fire and forget)
    registerForPushNotifications(api).catch(() => {});
  },

  disconnect: () => {
    connectSeq++; // abort any in-flight connect
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
