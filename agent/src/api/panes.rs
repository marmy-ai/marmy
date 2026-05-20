use axum::{
    extract::{Path, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};

use crate::state::AppState;

#[derive(Deserialize)]
pub struct InputRequest {
    pub keys: String,
    /// If true, send as raw text (literal). If false, interpret as tmux key names.
    #[serde(default)]
    pub literal: bool,
}

#[derive(Deserialize)]
pub struct ResizeRequest {
    pub cols: u32,
    pub rows: u32,
}

#[derive(Serialize)]
pub struct PaneContent {
    pub pane_id: String,
    pub content: String,
}

/// POST /api/panes/:id/input — send input to a pane.
pub async fn send_input(
    State(state): State<AppState>,
    Path(pane_id): Path<String>,
    Json(req): Json<InputRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let pane_id = normalize_pane_id(&pane_id);

    // If input ends with \n or \r, split into text + Enter (separate tmux commands).
    // This is critical for TUI apps like Claude Code that process keystrokes
    // individually — Enter must arrive as a distinct event, not in the same
    // byte chunk as the text.
    let input = &req.keys;
    if input.ends_with('\n') || input.ends_with('\r') {
        let text = input.trim_end_matches(|c| c == '\n' || c == '\r');
        state
            .tmux
            .send_text_enter(&pane_id, text)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    } else if is_text_payload(input) && pane_is_codex(&state, &pane_id).await {
        // Codex panes: auto-append Enter so the mobile "send" button works the
        // same as for Claude Code without requiring a separate Return press.
        state
            .tmux
            .send_text_enter(&pane_id, input)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    } else {
        // Raw control characters / escape sequences (Ctrl-C, Tab, arrows)
        let bytes: Vec<u8> = input.bytes().collect();
        state
            .tmux
            .send_bytes(&pane_id, &bytes)
            .await
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    }

    Ok(StatusCode::NO_CONTENT)
}

/// Returns true if the input looks like a plain text message with no control bytes
/// (so we can distinguish "send message" from "send Ctrl-C / arrow key / etc.").
fn is_text_payload(input: &str) -> bool {
    !input.is_empty() && input.bytes().all(|b| b >= 0x20 || b == 0x09)
}

/// Returns true if the pane's current command is Codex (uses cached topology).
async fn pane_is_codex(state: &AppState, pane_id: &str) -> bool {
    let Ok(topology) = state.get_topology().await else {
        return false;
    };
    topology
        .panes
        .iter()
        .find(|p| p.id == pane_id)
        .map(|p| is_codex_command(&p.current_command))
        .unwrap_or(false)
}

fn is_codex_command(command: &str) -> bool {
    let cmd = command.trim().to_ascii_lowercase();
    cmd == "codex" || cmd.ends_with("/codex") || cmd.contains("codex")
}

/// POST /api/panes/:id/resize — resize a pane (resizes the whole window).
pub async fn resize_pane(
    State(state): State<AppState>,
    Path(pane_id): Path<String>,
    Json(req): Json<ResizeRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let pane_id = normalize_pane_id(&pane_id);

    let topo = state
        .get_topology()
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    let pane = topo
        .panes
        .iter()
        .find(|p| p.id == pane_id)
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("pane {} not found", pane_id)))?;

    let session = topo
        .sessions
        .iter()
        .find(|s| s.id == pane.session_id)
        .ok_or_else(|| (StatusCode::NOT_FOUND, format!("session for pane {} not found", pane_id)))?;

    state
        .tmux
        .resize_window(&session.name, req.cols, req.rows)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(StatusCode::NO_CONTENT)
}

/// GET /api/panes/:id/content — capture current pane content.
pub async fn get_content(
    State(state): State<AppState>,
    Path(pane_id): Path<String>,
) -> Result<Json<PaneContent>, (StatusCode, String)> {
    let pane_id = normalize_pane_id(&pane_id);

    let content = state
        .tmux
        .capture_pane(&pane_id, false)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(PaneContent {
        pane_id: pane_id.clone(),
        content,
    }))
}

/// GET /api/panes/:id/history — capture full scrollback history.
pub async fn get_history(
    State(state): State<AppState>,
    Path(pane_id): Path<String>,
) -> Result<Json<PaneContent>, (StatusCode, String)> {
    let pane_id = normalize_pane_id(&pane_id);

    let content = state
        .tmux
        .capture_pane(&pane_id, true)
        .await
        .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;

    Ok(Json(PaneContent {
        pane_id: pane_id.clone(),
        content,
    }))
}

/// Normalize pane ID: clients send "3" but tmux expects "%3".
fn normalize_pane_id(id: &str) -> String {
    if id.starts_with('%') {
        id.to_string()
    } else {
        format!("%{}", id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_payload_accepts_plain_text() {
        assert!(is_text_payload("hello world"));
        assert!(is_text_payload("fix the bug in auth.rs"));
        assert!(is_text_payload("text with\ttab"));
    }

    #[test]
    fn text_payload_rejects_control_sequences() {
        assert!(!is_text_payload("\x03"));       // Ctrl-C
        assert!(!is_text_payload("\x1b[A"));     // arrow up
        assert!(!is_text_payload("\x1b"));       // escape
        assert!(!is_text_payload(""));
    }

    #[test]
    fn text_payload_rejects_newline_terminated() {
        // \n-terminated input is handled by the earlier branch, not this one
        assert!(!is_text_payload("hello\n"));
        assert!(!is_text_payload("hello\r"));
    }

    #[test]
    fn codex_command_detection() {
        assert!(is_codex_command("codex"));
        assert!(is_codex_command("/usr/local/bin/codex"));
        assert!(is_codex_command("node_modules/.bin/codex"));
        assert!(!is_codex_command("claude"));
        assert!(!is_codex_command("bash"));
        assert!(!is_codex_command(""));
    }

    #[test]
    fn normalize_pane_id_adds_prefix() {
        assert_eq!(normalize_pane_id("3"), "%3");
        assert_eq!(normalize_pane_id("%3"), "%3");
        assert_eq!(normalize_pane_id("0"), "%0");
    }
}
