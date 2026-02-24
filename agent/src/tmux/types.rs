use serde::{Deserialize, Serialize};

/// Unique tmux identifiers use prefix conventions: $session, @window, %pane.
/// These IDs are unique for the lifetime of the tmux server and never reused.

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TmuxSession {
    pub id: String,        // e.g. "$0"
    pub name: String,
    pub windows: Vec<String>, // window IDs
    pub attached: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TmuxWindow {
    pub id: String,        // e.g. "@0"
    pub session_id: String,
    pub index: u32,
    pub name: String,
    pub panes: Vec<String>, // pane IDs
    pub active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TmuxPane {
    pub id: String,          // e.g. "%0"
    pub window_id: String,
    pub session_id: String,
    pub index: u32,
    pub width: u32,
    pub height: u32,
    pub active: bool,
    pub current_command: String,
    pub current_path: String,
    pub pid: u32,
}

/// Full topology snapshot sent to clients on connect.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TmuxTopology {
    pub sessions: Vec<TmuxSession>,
    pub windows: Vec<TmuxWindow>,
    pub panes: Vec<TmuxPane>,
}

/// Events parsed from tmux control mode notifications.
#[derive(Debug, Clone)]
pub enum TmuxEvent {
    // Pane output: the core streaming event
    Output {
        pane_id: String,
        data: Vec<u8>,
    },

    // Topology changes
    WindowAdd { window_id: String },
    WindowClose { window_id: String },
    WindowRenamed { window_id: String, name: String },
    SessionChanged { session_id: String, name: String },
    SessionsChanged,
    SessionRenamed { session_id: String, name: String },
    SessionWindowChanged { session_id: String, window_id: String },
    LayoutChange { window_id: String, layout: String },
    PaneModeChanged { pane_id: String },

    // Control client lifecycle
    Exit { reason: String },
}

/// Result of a command sent via control mode.
#[derive(Debug, Clone)]
pub struct CommandResult {
    pub success: bool,
    pub lines: Vec<String>,
}

/// Messages sent from WebSocket clients to the agent.
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum ClientMessage {
    #[serde(rename = "subscribe_pane")]
    SubscribePane { pane_id: String },
    #[serde(rename = "unsubscribe_pane")]
    UnsubscribePane { pane_id: String },
    #[serde(rename = "input")]
    Input { pane_id: String, keys: String },
    #[serde(rename = "resize")]
    Resize { pane_id: String, cols: u32, rows: u32 },
}

/// Messages sent from the agent to WebSocket clients.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type")]
pub enum ServerMessage {
    #[serde(rename = "pane_output")]
    PaneOutput { pane_id: String, data: String },
    #[serde(rename = "topology")]
    Topology(TmuxTopology),
    #[serde(rename = "session_event")]
    SessionEvent { event: String, detail: String },
    #[serde(rename = "error")]
    Error { message: String },
}
