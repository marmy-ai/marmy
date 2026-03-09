// Types matching the marmy-agent API contract

export interface Machine {
  id: string;
  name: string;
  address: string; // host:port
  token: string;
  online: boolean;
}

export interface TmuxSession {
  id: string;
  name: string;
  windows: string[];
  attached: boolean;
}

export interface TmuxWindow {
  id: string;
  session_id: string;
  index: number;
  name: string;
  panes: string[];
  active: boolean;
}

export interface TmuxPane {
  id: string;
  window_id: string;
  session_id: string;
  index: number;
  width: number;
  height: number;
  active: boolean;
  current_command: string;
  current_path: string;
  pid: number;
}

export interface TmuxTopology {
  sessions: TmuxSession[];
  windows: TmuxWindow[];
  panes: TmuxPane[];
}

export interface SessionRoot {
  path: string;
  pane_id: string;
  window_name: string;
  current_command: string;
}

export interface DirEntry {
  name: string;
  path: string;
  is_dir: boolean;
  size: number;
}

export interface DirListing {
  path: string;
  entries: DirEntry[];
}

export interface FileContent {
  path: string;
  content: string;
  size: number;
}

export interface PaneContent {
  pane_id: string;
  content: string;
}

// CC Dashboard types

export interface CcSession {
  session_name: string;
  pane_id: string;
  project_path: string;
  current_command: string;
}

export interface CcSessionContext {
  pane_id: string;
  pane_content: string;
  last_user_inputs: string[];
  last_assistant_output: string | null;
}

export interface DashboardStartResponse {
  pane_id: string;
  session_name: string;
}

export interface CreateSessionResponse {
  pane_id: string;
  session_name: string;
}

export interface VoiceTokenResponse {
  token: string;
}

// WebSocket messages (client -> server)
export type ClientMessage =
  | { type: "subscribe_pane"; pane_id: string }
  | { type: "unsubscribe_pane"; pane_id: string }
  | { type: "input"; pane_id: string; keys: string }
  | { type: "resize"; pane_id: string; cols: number; rows: number }
  | { type: "ping" };

// WebSocket messages (server -> client)
export type ServerMessage =
  | { type: "pane_output"; pane_id: string; data: string }
  | { type: "pong" }
  | { type: "topology"; sessions: TmuxSession[]; windows: TmuxWindow[]; panes: TmuxPane[] }
  | { type: "session_event"; event: string; detail: string }
  | { type: "notification"; event: "task_complete" | "waiting_for_input"; pane_id: string; session_name: string; message: string }
  | { type: "error"; message: string };
