use axum::{
    extract::{
        ws::{Message, WebSocket},
        State, WebSocketUpgrade,
    },
    response::Response,
};
use futures::{SinkExt, StreamExt};
use tracing::{debug, info};

use crate::state::AppState;
use crate::tmux::types::{ClientMessage, ServerMessage};

/// GET /ws — WebSocket endpoint for real-time topology updates and input.
pub async fn ws_handler(
    ws: WebSocketUpgrade,
    State(state): State<AppState>,
) -> Response {
    ws.on_upgrade(move |socket| handle_socket(socket, state))
}

async fn handle_socket(socket: WebSocket, state: AppState) {
    let (mut ws_tx, mut ws_rx) = socket.split();
    let mut topo_rx = state.topology_rx.clone();

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
            // Watch for topology changes and push to client
            result = topo_rx.changed() => {
                if result.is_err() {
                    // Sender dropped — shutting down
                    break;
                }
                let topology = topo_rx.borrow_and_update().clone();
                if let Some(topology) = topology {
                    let msg = ServerMessage::Topology(topology);
                    if let Ok(json) = serde_json::to_string(&msg) {
                        if ws_tx.send(Message::Text(json.into())).await.is_err() {
                            break;
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
