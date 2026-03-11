use std::collections::{HashMap, HashSet};

use axum::{
    extract::{
        ws::{Message, WebSocket},
        Query, State, WebSocketUpgrade,
    },
    http::StatusCode,
    response::Response,
};
use futures::{SinkExt, StreamExt};
use serde::Deserialize;
use tracing::{debug, info};

use crate::state::AppState;
use crate::tmux::types::{ClientMessage, EnrichedTopology, ServerMessage};

#[derive(Deserialize)]
pub struct WsAuthQuery {
    token: String,
}

/// GET /ws?token=... — WebSocket endpoint for real-time topology updates, pane streaming, and input.
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    Query(auth): Query<WsAuthQuery>,
    State(state): State<AppState>,
) -> Result<Response, StatusCode> {
    if auth.token != state.config.auth.token {
        return Err(StatusCode::UNAUTHORIZED);
    }
    Ok(ws.on_upgrade(move |socket| handle_socket(socket, state)))
}

/// Normalize pane ID: clients send "3" but tmux expects "%3".
fn normalize_pane_id(id: &str) -> String {
    if id.starts_with('%') {
        id.to_string()
    } else {
        format!("%{}", id)
    }
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let mut topo_rx = state.topology_rx.clone();

    // Pane subscription state
    let mut subscribed_panes: HashSet<String> = HashSet::new();
    let mut last_content: HashMap<String, String> = HashMap::new();
    let mut pane_tick = tokio::time::interval(std::time::Duration::from_millis(300));

    // Send initial topology snapshot (enriched with unread state)
    match state.get_topology().await {
        Ok(topology) => {
            let unread = state.get_unread_sessions().await;
            let enriched = EnrichedTopology::from(&topology, &unread);
            let msg = ServerMessage::Topology(enriched);
            if let Ok(json) = serde_json::to_string(&msg) {
                let _ = ws_tx.send(Message::Text(json.into())).await;
            }
        }
        Err(e) => {
            let msg = ServerMessage::Error {
                message: format!("failed to get topology: {}", e),
            };
            if let Ok(json) = serde_json::to_string(&msg) {
                let _ = ws_tx.send(Message::Text(json.into())).await;
            }
        }
    }

    info!("WebSocket client connected");

    loop {
        tokio::select! {
            // Watch for topology changes and push to client
            result = topo_rx.changed() => {
                if result.is_err() {
                    break;
                }
                let topology = topo_rx.borrow_and_update().clone();
                if let Some(topology) = topology {
                    let unread = state.get_unread_sessions().await;
                    let enriched = EnrichedTopology::from(&topology, &unread);
                    let msg = ServerMessage::Topology(enriched);
                    if let Ok(json) = serde_json::to_string(&msg) {
                        if ws_tx.send(Message::Text(json.into())).await.is_err() {
                            break;
                        }
                    }
                }
            }

            // Poll subscribed panes for content changes
            _ = pane_tick.tick() => {
                for pane_id in &subscribed_panes {
                    if let Ok(content) = state.tmux.capture_pane(pane_id, true).await {
                        let changed = last_content.get(pane_id).map_or(true, |prev| prev != &content);
                        if changed {
                            last_content.insert(pane_id.clone(), content.clone());
                            let msg = ServerMessage::PaneOutput {
                                pane_id: pane_id.clone(),
                                data: content,
                            };
                            if let Ok(json) = serde_json::to_string(&msg) {
                                if ws_tx.send(Message::Text(json.into())).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                }
            }

            // Handle messages from the WebSocket client
            msg = ws_rx.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        match serde_json::from_str::<ClientMessage>(&text) {
                            Ok(ClientMessage::Input { pane_id, keys }) => {
                                let pane_id = normalize_pane_id(&pane_id);
                                if keys.ends_with('\n') || keys.ends_with('\r') {
                                    let text = keys.trim_end_matches(|c| c == '\n' || c == '\r');
                                    let _ = state.tmux.send_text_enter(&pane_id, text).await;
                                } else {
                                    let bytes: Vec<u8> = keys.bytes().collect();
                                    let _ = state.tmux.send_bytes(&pane_id, &bytes).await;
                                }
                                // Immediately push updated content if this pane is subscribed
                                if subscribed_panes.contains(&pane_id) {
                                    if let Ok(content) = state.tmux.capture_pane(&pane_id, true).await {
                                        let changed = last_content.get(&pane_id).map_or(true, |prev| prev != &content);
                                        if changed {
                                            last_content.insert(pane_id.clone(), content.clone());
                                            let msg = ServerMessage::PaneOutput {
                                                pane_id: pane_id.clone(),
                                                data: content,
                                            };
                                            if let Ok(json) = serde_json::to_string(&msg) {
                                                let _ = ws_tx.send(Message::Text(json.into())).await;
                                            }
                                        }
                                    }
                                }
                            }
                            Ok(ClientMessage::Resize { pane_id, cols, rows }) => {
                                let pane_id = normalize_pane_id(&pane_id);
                                if let Ok(topo) = state.get_topology().await {
                                    if let Some(pane) = topo.panes.iter().find(|p| p.id == pane_id) {
                                        if let Some(session) = topo.sessions.iter().find(|s| s.id == pane.session_id) {
                                            let _ = state.tmux.resize_window(&session.name, cols, rows).await;
                                        }
                                    }
                                }
                            }
                            Ok(ClientMessage::SubscribePane { pane_id }) => {
                                let pane_id = normalize_pane_id(&pane_id);
                                subscribed_panes.insert(pane_id.clone());
                                // Send initial content immediately
                                if let Ok(content) = state.tmux.capture_pane(&pane_id, true).await {
                                    last_content.insert(pane_id.clone(), content.clone());
                                    let msg = ServerMessage::PaneOutput {
                                        pane_id: pane_id.clone(),
                                        data: content,
                                    };
                                    if let Ok(json) = serde_json::to_string(&msg) {
                                        let _ = ws_tx.send(Message::Text(json.into())).await;
                                    }
                                }
                            }
                            Ok(ClientMessage::UnsubscribePane { pane_id }) => {
                                let pane_id = normalize_pane_id(&pane_id);
                                subscribed_panes.remove(&pane_id);
                                last_content.remove(&pane_id);
                            }
                            Ok(ClientMessage::Ping) => {
                                let msg = ServerMessage::Pong;
                                if let Ok(json) = serde_json::to_string(&msg) {
                                    if ws_tx.send(Message::Text(json.into())).await.is_err() {
                                        break;
                                    }
                                }
                            }
                            Err(e) => {
                                debug!(error = %e, "failed to parse client message");
                            }
                        }
                    }
                    Some(Ok(Message::Close(_))) | None => break,
                    Some(Ok(Message::Ping(data))) => {
                        let _ = ws_tx.send(Message::Pong(data)).await;
                    }
                    _ => {}
                }
            }
        }
    }

    info!("WebSocket client disconnected");
}
