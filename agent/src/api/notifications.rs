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
    /// "relay" = forward to hosted relay, "local" = direct APNs. Default: "local".
    #[serde(default = "default_provider")]
    pub push_provider: String,
}

fn default_provider() -> String {
    "local".to_string()
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
    info!("registering push token: {}... (provider: {})", &body.token[..body.token.len().min(20)], body.push_provider);
    state.register_push_token(body.token, body.push_provider).await;
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

    // Mark session as unread (reliable fallback — works without APNs)
    if !session.is_empty() && session != "Session" {
        state.mark_session_unread(session.clone()).await;
    }

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
    let token = &state.config.auth.token;
    match write_claude_hook(body.enabled, port, token) {
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

fn write_claude_hook(enabled: bool, port: u16, token: &str) -> Result<(), String> {
    let mut settings = read_settings();

    if enabled {
        // Build the Stop hook entry — token is hardcoded since this is a local config file
        let hook_entry = serde_json::json!([{
            "hooks": [{
                "type": "command",
                "command": format!(
                    "curl -sX POST http://localhost:{}/api/notifications/send -H 'Content-Type: application/json' -H 'Authorization: Bearer {}' -d @-",
                    port, token
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
/// which session Claude is running in. Uses multiple strategies:
/// 1. Longest prefix match: pane path is a prefix of cwd (e.g. pane at /projects, cwd is /projects/marmy/src)
/// 2. Reverse prefix: cwd is a prefix of pane path (e.g. cwd is /projects, pane at /projects/marmy)
/// 3. Single-session fallback: if only one non-manager session exists, use it
async fn resolve_session_name(state: &AppState, cwd: &str) -> Option<String> {
    let topology = state.get_topology().await.ok()?;
    let cwd_path = std::path::Path::new(cwd);

    // Only consider panes belonging to visible sessions (excludes _marmy_ctrl etc.)
    let session_ids: std::collections::HashSet<&str> = topology.sessions.iter()
        .map(|s| s.id.as_str())
        .collect();

    let visible_panes: Vec<_> = topology.panes.iter()
        .filter(|p| !p.current_path.is_empty())
        .filter(|p| session_ids.contains(p.session_id.as_str()))
        .collect();

    // Strategy 1: pane path is a prefix of cwd (original behavior)
    let best = visible_panes.iter()
        .filter(|p| cwd_path.starts_with(&p.current_path))
        .max_by_key(|p| p.current_path.len());

    if let Some(pane) = best {
        return topology.sessions.iter()
            .find(|s| s.id == pane.session_id)
            .map(|s| s.name.clone());
    }

    // Strategy 2: cwd is a prefix of a pane path (reverse match)
    let reverse = visible_panes.iter()
        .filter(|p| std::path::Path::new(&p.current_path).starts_with(cwd_path))
        .max_by_key(|p| p.current_path.len());

    if let Some(pane) = reverse {
        return topology.sessions.iter()
            .find(|s| s.id == pane.session_id)
            .map(|s| s.name.clone());
    }

    // Strategy 3: if there's only one non-manager session, it's almost certainly the right one
    let user_sessions: Vec<_> = topology.sessions.iter()
        .filter(|s| s.name != "sessions-manager")
        .collect();
    if user_sessions.len() == 1 {
        return Some(user_sessions[0].name.clone());
    }

    None
}

fn is_hook_enabled() -> bool {
    let settings = read_settings();
    settings.get("hooks")
        .and_then(|h| h.get("Stop"))
        .and_then(|s| s.as_array())
        .map(|arr| !arr.is_empty())
        .unwrap_or(false)
}

/// If the hook is already enabled, rewrite it with current port/token.
/// Call on agent startup so deploying a new agent version updates the hook.
pub fn refresh_hook_if_enabled(port: u16, token: &str) {
    if is_hook_enabled() {
        if let Err(e) = write_claude_hook(true, port, token) {
            tracing::warn!("failed to refresh notification hook: {}", e);
        } else {
            tracing::info!("refreshed notification hook with current config");
        }
    }
}

#[cfg(test)]
mod tests {
    // Test the hook JSON structure construction without hitting the real filesystem.
    // We replicate the JSON logic from write_claude_hook inline.

    /// Build the hook JSON the same way write_claude_hook does.
    fn build_hook_json(settings: &mut serde_json::Value, enabled: bool, port: u16, token: &str) {
        if enabled {
            let hook_entry = serde_json::json!([{
                "hooks": [{
                    "type": "command",
                    "command": format!(
                        "curl -sX POST http://localhost:{}/api/notifications/send -H 'Content-Type: application/json' -H 'Authorization: Bearer {}' -d @-",
                        port, token
                    ),
                    "timeout": 5
                }]
            }]);
            if settings.get("hooks").is_none() {
                settings["hooks"] = serde_json::json!({});
            }
            settings["hooks"]["Stop"] = hook_entry;
        } else {
            if let Some(hooks) = settings.get_mut("hooks") {
                if let Some(obj) = hooks.as_object_mut() {
                    obj.remove("Stop");
                    if obj.is_empty() {
                        // Can't remove from root here without owning it,
                        // so just mark for caller
                    }
                }
            }
        }
    }

    fn check_hook_enabled(settings: &serde_json::Value) -> bool {
        settings.get("hooks")
            .and_then(|h| h.get("Stop"))
            .and_then(|s| s.as_array())
            .map(|arr| !arr.is_empty())
            .unwrap_or(false)
    }

    #[test]
    fn hook_enable_creates_stop_entry() {
        let mut settings = serde_json::json!({});
        build_hook_json(&mut settings, true, 9876, "test-token");

        assert!(check_hook_enabled(&settings));
        let cmd = settings["hooks"]["Stop"][0]["hooks"][0]["command"].as_str().unwrap();
        assert!(cmd.contains("9876"));
        assert!(cmd.contains("test-token"));
        assert!(cmd.contains("curl"));
    }

    #[test]
    fn hook_enable_embeds_correct_port_and_token() {
        let mut settings = serde_json::json!({});
        build_hook_json(&mut settings, true, 4444, "my-secret");

        let cmd = settings["hooks"]["Stop"][0]["hooks"][0]["command"].as_str().unwrap();
        assert!(cmd.contains("localhost:4444"));
        assert!(cmd.contains("Bearer my-secret"));
    }

    #[test]
    fn hook_disable_removes_stop_entry() {
        let mut settings = serde_json::json!({});
        build_hook_json(&mut settings, true, 9876, "tok");
        assert!(check_hook_enabled(&settings));

        build_hook_json(&mut settings, false, 9876, "tok");
        assert!(!check_hook_enabled(&settings));
    }

    #[test]
    fn hook_disable_on_empty_settings_is_noop() {
        let mut settings = serde_json::json!({});
        build_hook_json(&mut settings, false, 9876, "tok");
        assert!(!check_hook_enabled(&settings));
        // Should not have created a hooks key
        assert!(settings.get("hooks").is_none());
    }

    #[test]
    fn hook_enable_preserves_existing_settings() {
        let mut settings = serde_json::json!({
            "someOtherKey": true,
            "hooks": {
                "PreToolUse": [{"hooks": [{"type": "command", "command": "echo hi"}]}]
            }
        });
        build_hook_json(&mut settings, true, 9876, "tok");

        // Stop hook added
        assert!(check_hook_enabled(&settings));
        // Existing key preserved
        assert_eq!(settings["someOtherKey"], true);
        // Existing hook preserved
        assert!(settings["hooks"]["PreToolUse"].is_array());
    }

    #[test]
    fn hook_enable_then_re_enable_updates_token() {
        let mut settings = serde_json::json!({});
        build_hook_json(&mut settings, true, 9876, "old-token");
        build_hook_json(&mut settings, true, 9876, "new-token");

        let cmd = settings["hooks"]["Stop"][0]["hooks"][0]["command"].as_str().unwrap();
        assert!(cmd.contains("new-token"));
        assert!(!cmd.contains("old-token"));
    }

    #[test]
    fn hook_timeout_is_5_seconds() {
        let mut settings = serde_json::json!({});
        build_hook_json(&mut settings, true, 9876, "tok");

        let timeout = settings["hooks"]["Stop"][0]["hooks"][0]["timeout"].as_u64().unwrap();
        assert_eq!(timeout, 5);
    }
}
