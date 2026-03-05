use std::path::PathBuf;

use axum::{
    extract::State,
    http::StatusCode,
    Json,
};
use serde::Deserialize;
use tracing::{info, warn};

use crate::state::AppState;

#[derive(Deserialize)]
pub struct TokenRequest {
    pub token: String,
}

#[derive(Deserialize)]
pub struct SendRequest {
    #[serde(default)]
    pub session: String,
    #[serde(default)]
    pub body: String,
    /// Working directory from Claude Code Stop hook stdin
    #[serde(default)]
    pub cwd: String,
    /// Stop reason from Claude Code Stop hook stdin (e.g. "end_turn")
    #[serde(default)]
    pub stop_reason: String,
}

#[derive(Deserialize)]
pub struct HookRequest {
    pub enabled: bool,
}

/// POST /api/notifications/register
pub async fn register_token(
    State(state): State<AppState>,
    Json(body): Json<TokenRequest>,
) -> StatusCode {
    info!("registering push token: {}...", &body.token[..body.token.len().min(20)]);
    state.register_push_token(body.token).await;
    StatusCode::OK
}

/// DELETE /api/notifications/register
pub async fn unregister_token(
    State(state): State<AppState>,
    Json(body): Json<TokenRequest>,
) -> StatusCode {
    info!("unregistering push token");
    state.unregister_push_token(&body.token).await;
    StatusCode::OK
}

/// POST /api/notifications/send — called by Claude via curl when a task finishes.
pub async fn send_notification(
    State(state): State<AppState>,
    body: Option<Json<SendRequest>>,
) -> Result<StatusCode, (StatusCode, String)> {
    let tokens = state.get_push_tokens().await;
    if tokens.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "no push tokens registered".to_string()));
    }

    let (session, msg) = match body {
        Some(Json(b)) => {
            // Match cwd against tmux pane paths to find the session name
            let title = if !b.cwd.is_empty() {
                resolve_session_name(&state, &b.cwd).await
                    .unwrap_or_else(|| b.session.clone())
            } else {
                b.session.clone()
            };
            let title = if title.is_empty() { "Session".to_string() } else { title };
            let body_text = if !b.body.is_empty() {
                b.body
            } else {
                "Task complete".to_string()
            };
            (title, body_text)
        }
        None => ("Session".to_string(), "Task complete".to_string()),
    };

    state.sender.send(&tokens, &session, &msg, "", &session, "task_complete").await;
    info!("sent push notification for session '{}'", session);
    Ok(StatusCode::OK)
}

/// POST /api/notifications/test
pub async fn test_notification(
    State(state): State<AppState>,
) -> Result<StatusCode, (StatusCode, String)> {
    let tokens = state.get_push_tokens().await;
    if tokens.is_empty() {
        return Err((StatusCode::BAD_REQUEST, "no push tokens registered".to_string()));
    }

    state.sender.send_test(&tokens).await;
    info!("sent test notification to {} token(s)", tokens.len());
    Ok(StatusCode::OK)
}

/// POST /api/notifications/hook — enable/disable the Claude Code Stop hook.
pub async fn set_hook(
    State(state): State<AppState>,
    Json(body): Json<HookRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let port = state.config.server.port;
    match write_claude_hook(body.enabled, port) {
        Ok(_) => {
            info!("claude Stop hook {}", if body.enabled { "enabled" } else { "disabled" });
            Ok(StatusCode::OK)
        }
        Err(e) => {
            warn!("failed to update claude hook: {}", e);
            Err((StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
        }
    }
}

/// GET /api/notifications/debug
pub async fn debug_notifications(
    State(state): State<AppState>,
) -> Json<serde_json::Value> {
    let tokens = state.get_push_tokens().await;
    let hook_enabled = is_hook_enabled();
    Json(serde_json::json!({
        "configured": state.sender.is_configured(),
        "registered_tokens": tokens.len(),
        "hook_enabled": hook_enabled,
    }))
}

// --- Claude Code settings.json hook management ---

fn claude_settings_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join(".claude")
        .join("settings.json")
}

fn read_settings() -> serde_json::Value {
    let path = claude_settings_path();
    if let Ok(content) = std::fs::read_to_string(&path) {
        serde_json::from_str(&content).unwrap_or_else(|_| serde_json::json!({}))
    } else {
        serde_json::json!({})
    }
}

fn write_settings(settings: &serde_json::Value) -> Result<(), String> {
    let path = claude_settings_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let content = serde_json::to_string_pretty(settings).map_err(|e| e.to_string())?;
    std::fs::write(&path, content).map_err(|e| e.to_string())
}

fn write_claude_hook(enabled: bool, port: u16) -> Result<(), String> {
    let mut settings = read_settings();

    if enabled {
        // Build the Stop hook entry
        let hook_entry = serde_json::json!([{
            "hooks": [{
                "type": "command",
                "command": format!(
                    "curl -sX POST http://localhost:{}/api/notifications/send -H 'Content-Type: application/json' -d @-",
                    port
                ),
                "timeout": 5
            }]
        }]);

        // Ensure hooks object exists
        if settings.get("hooks").is_none() {
            settings["hooks"] = serde_json::json!({});
        }
        settings["hooks"]["Stop"] = hook_entry;
    } else {
        // Remove the Stop hook
        if let Some(hooks) = settings.get_mut("hooks") {
            if let Some(obj) = hooks.as_object_mut() {
                obj.remove("Stop");
                // Clean up empty hooks object
                if obj.is_empty() {
                    if let Some(root) = settings.as_object_mut() {
                        root.remove("hooks");
                    }
                }
            }
        }
    }

    write_settings(&settings)
}

/// Match the hook's cwd against tmux pane working directories to find
/// which session Claude is running in. Picks the longest matching prefix
/// so `/projects/marmy/agent` matches a pane at `/projects/marmy`.
async fn resolve_session_name(state: &AppState, cwd: &str) -> Option<String> {
    let topology = state.get_topology().await.ok()?;
    let cwd_path = std::path::Path::new(cwd);

    // Only consider panes belonging to visible sessions (excludes _marmy_ctrl etc.)
    let session_ids: std::collections::HashSet<&str> = topology.sessions.iter()
        .map(|s| s.id.as_str())
        .collect();

    // Find the pane whose current_path is the longest prefix of cwd
    let best = topology.panes.iter()
        .filter(|p| !p.current_path.is_empty())
        .filter(|p| session_ids.contains(p.session_id.as_str()))
        .filter(|p| cwd_path.starts_with(&p.current_path))
        .max_by_key(|p| p.current_path.len())?;

    topology.sessions.iter()
        .find(|s| s.id == best.session_id)
        .map(|s| s.name.clone())
}

fn is_hook_enabled() -> bool {
    let settings = read_settings();
    settings.get("hooks")
        .and_then(|h| h.get("Stop"))
        .and_then(|s| s.as_array())
        .map(|arr| !arr.is_empty())
        .unwrap_or(false)
}
