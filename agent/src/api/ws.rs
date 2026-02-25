use std::collections::HashSet;

use axum::{
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    response::Response,
};
use futures::{SinkExt, StreamExt};
use tokio::sync::broadcast;
use tracing::{debug, info, warn};

use crate::state::AppState;
use crate::tmux::types::{ClientMessage, ServerMessage, TmuxEvent};

/// GET /ws — WebSocket endpoint for real-time terminal streaming.
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Response {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let mut event_rx = state.tmux.subscribe();

    // Track which panes this client is subscribed to
    let mut subscribed_panes: HashSet<String> = HashSet::new();

    // Send initial topology snapshot
    match state.get_topology().await {
        Ok(topology) => {
            let msg = ServerMessage::Topology(topology);
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
            // Forward tmux events to the WebSocket client
            event = event_rx.recv() => {
                match event {
                    Ok(TmuxEvent::Output { pane_id, data }) => {
                        if subscribed_panes.contains(&pane_id) {
                            let text = String::from_utf8_lossy(&data).to_string();
                            let msg = ServerMessage::PaneOutput {
                                pane_id,
                                data: text,
                            };
                            if let Ok(json) = serde_json::to_string(&msg) {
                                if ws_tx.send(Message::Text(json.into())).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    Ok(TmuxEvent::SessionsChanged)
                    | Ok(TmuxEvent::WindowAdd { .. })
                    | Ok(TmuxEvent::WindowClose { .. })
                    | Ok(TmuxEvent::WindowRenamed { .. }) => {
                        // Topology changed — send fresh snapshot
                        if let Ok(topology) = state.get_topology().await {
                            let msg = ServerMessage::Topology(topology);
                            if let Ok(json) = serde_json::to_string(&msg) {
                                if ws_tx.send(Message::Text(json.into())).await.is_err() {
                                    break;
                                }
                            }
                        }
                    }
                    Ok(TmuxEvent::Exit { reason }) => {
                        let msg = ServerMessage::SessionEvent {
                            event: "exit".to_string(),
                            detail: reason,
                        };
                        if let Ok(json) = serde_json::to_string(&msg) {
                            let _ = ws_tx.send(Message::Text(json.into())).await;
                        }
                        break;
                    }
                    Ok(event) => {
                        let msg = ServerMessage::SessionEvent {
                            event: format!("{:?}", event),
                            detail: String::new(),
                        };
                        if let Ok(json) = serde_json::to_string(&msg) {
                            if ws_tx.send(Message::Text(json.into())).await.is_err() {
                                break;
                            }
                        }
                    }
                    Err(broadcast::error::RecvError::Lagged(n)) => {
                        warn!(count = n, "WebSocket client lagged, dropped events");
                    }
                    Err(broadcast::error::RecvError::Closed) => break,
                }
            }

            // Handle messages from the WebSocket client
            msg = ws_rx.next() => {
                match msg {
                    Some(Ok(Message::Text(text))) => {
                        match serde_json::from_str::<ClientMessage>(&text) {
                            Ok(ClientMessage::SubscribePane { pane_id }) => {
                                debug!(pane_id = %pane_id, "client subscribed to pane");
                                // Look up the pane's session from cached topology and switch
                                // the control client there so %output events flow.
                                if let Ok(topo) = state.get_topology().await {
                                    if let Some(pane) = topo.panes.iter().find(|p| p.id == pane_id) {
                                        let sid = pane.session_id.clone();
                                        if let Err(e) = state.tmux.switch_client_to_session(&sid).await {
                                            warn!(error = %e, session = %sid, "failed to switch session");
                                        } else {
                                            info!(pane = %pane_id, session = %sid, "switched control client to session");
                                        }
                                    }
                                }
                                subscribed_panes.insert(pane_id);
                            }
                            Ok(ClientMessage::UnsubscribePane { pane_id }) => {
                                debug!(pane_id = %pane_id, "client unsubscribed from pane");
                                subscribed_panes.remove(&pane_id);
                            }
                            Ok(ClientMessage::Input { pane_id, keys }) => {
                                if keys.ends_with('\n') || keys.ends_with('\r') {
                                    let text = keys.trim_end_matches(|c| c == '\n' || c == '\r');
                                    let _ = state.tmux.send_text_enter(&pane_id, text).await;
                                } else {
                                    let bytes: Vec<u8> = keys.bytes().collect();
                                    let _ = state.tmux.send_bytes(&pane_id, &bytes).await;
                                }
                            }
                            Ok(ClientMessage::Resize { pane_id, cols, rows }) => {
                                let _ = state.tmux.resize_pane(&pane_id, cols, rows).await;
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
