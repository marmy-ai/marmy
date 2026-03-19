use std::collections::HashSet;

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

/// A session enriched with ephemeral state (e.g. unread flag).
#[derive(Debug, Clone, Serialize)]
pub struct EnrichedSession {
    #[serde(flatten)]
    pub session: TmuxSession,
    pub unread: bool,
}

/// Enriched topology sent over the wire (REST + WebSocket).
#[derive(Debug, Clone, Serialize)]
pub struct EnrichedTopology {
    pub sessions: Vec<EnrichedSession>,
    pub windows: Vec<TmuxWindow>,
    pub panes: Vec<TmuxPane>,
}

impl EnrichedTopology {
    pub fn from(topology: &TmuxTopology, unread_set: &HashSet<String>) -> Self {
        Self {
            sessions: topology
                .sessions
                .iter()
                .map(|s| EnrichedSession {
                    unread: unread_set.contains(&s.name),
                    session: s.clone(),
                })
                .collect(),
            windows: topology.windows.clone(),
            panes: topology.panes.clone(),
        }
    }
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
    Topology(EnrichedTopology),
    #[serde(rename = "pane_output")]
    PaneOutput { pane_id: String, data: String },
    #[serde(rename = "pong")]
    Pong,
    #[serde(rename = "error")]
    Error { message: String },
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_session(id: &str, name: &str) -> TmuxSession {
        TmuxSession {
            id: id.to_string(),
            name: name.to_string(),
            windows: vec![],
            attached: false,
        }
    }

    #[test]
    fn enriched_from_empty_topology() {
        let topo = TmuxTopology { sessions: vec![], windows: vec![], panes: vec![] };
        let unread = HashSet::new();
        let enriched = EnrichedTopology::from(&topo, &unread);
        assert!(enriched.sessions.is_empty());
    }

    #[test]
    fn enriched_marks_matching_sessions_unread() {
        let topo = TmuxTopology {
            sessions: vec![
                make_session("$0", "worker-1"),
                make_session("$1", "worker-2"),
                make_session("$2", "worker-3"),
            ],
            windows: vec![],
            panes: vec![],
        };
        let unread: HashSet<String> = ["worker-2".to_string()].into();
        let enriched = EnrichedTopology::from(&topo, &unread);

        assert!(!enriched.sessions[0].unread);
        assert!(enriched.sessions[1].unread);
        assert!(!enriched.sessions[2].unread);
    }

    #[test]
    fn enriched_unread_set_with_nonexistent_session_no_panic() {
        let topo = TmuxTopology {
            sessions: vec![make_session("$0", "real")],
            windows: vec![],
            panes: vec![],
        };
        let unread: HashSet<String> = ["ghost".to_string()].into();
        let enriched = EnrichedTopology::from(&topo, &unread);

        assert_eq!(enriched.sessions.len(), 1);
        assert!(!enriched.sessions[0].unread);
    }

    #[test]
    fn enriched_preserves_windows_and_panes() {
        let topo = TmuxTopology {
            sessions: vec![make_session("$0", "dev")],
            windows: vec![TmuxWindow {
                id: "@0".into(), session_id: "$0".into(),
                index: 0, name: "bash".into(), panes: vec![], active: true,
            }],
            panes: vec![TmuxPane {
                id: "%0".into(), window_id: "@0".into(), session_id: "$0".into(),
                index: 0, width: 120, height: 40, active: true,
                current_command: "claude".into(), current_path: "/home".into(), pid: 123,
            }],
        };
        let enriched = EnrichedTopology::from(&topo, &HashSet::new());

        assert_eq!(enriched.windows.len(), 1);
        assert_eq!(enriched.windows[0].id, "@0");
        assert_eq!(enriched.panes.len(), 1);
        assert_eq!(enriched.panes[0].current_command, "claude");
    }

    #[test]
    fn enriched_all_sessions_unread() {
        let topo = TmuxTopology {
            sessions: vec![make_session("$0", "a"), make_session("$1", "b")],
            windows: vec![],
            panes: vec![],
        };
        let unread: HashSet<String> = ["a".to_string(), "b".to_string()].into();
        let enriched = EnrichedTopology::from(&topo, &unread);

        assert!(enriched.sessions.iter().all(|s| s.unread));
    }
}
