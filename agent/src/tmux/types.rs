use serde::{Deserialize, Serialize};

/// Unique tmux identifiers use prefix conventions: $session, @window, %pane.
/// These IDs are unique for the lifetime of the tmux server and never reused.

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TmuxSession {
    pub id: String,        // e.g. "$0"
    pub name: String,
    pub windows: Vec<String>, // window IDs
    pub attached: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TmuxWindow {
    pub id: String,        // e.g. "@0"
    pub session_id: String,
    pub index: u32,
    pub name: String,
    pub panes: Vec<String>, // pane IDs
    pub active: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
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
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct TmuxTopology {
    pub sessions: Vec<TmuxSession>,
    pub windows: Vec<TmuxWindow>,
    pub panes: Vec<TmuxPane>,
}

/// Messages sent from WebSocket clients to the agent.
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum ClientMessage {
    #[serde(rename = "input")]
    Input { pane_id: String, keys: String },
    #[serde(rename = "resize")]
    Resize { pane_id: String, cols: u32, rows: u32 },
    #[serde(rename = "subscribe_pane")]
    SubscribePane { pane_id: String },
    #[serde(rename = "unsubscribe_pane")]
    UnsubscribePane { pane_id: String },
    #[serde(rename = "ping")]
    Ping,
}

/// Messages sent from the agent to WebSocket clients.
#[derive(Debug, Clone, Serialize)]
#[serde(tag = "type")]
pub enum ServerMessage {
    #[serde(rename = "topology")]
    Topology(TmuxTopology),
    #[serde(rename = "pane_output")]
    PaneOutput { pane_id: String, data: String },
    #[serde(rename = "pong")]
    Pong,
    #[serde(rename = "error")]
    Error { message: String },
}
