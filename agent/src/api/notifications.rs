use std::collections::{hash_map::DefaultHasher, HashMap};
use std::hash::{Hash, Hasher};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use axum::{extract::State, http::StatusCode, Json};
use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::state::AppState;

const CODEX_WATCHER_POLL_SECONDS: u64 = 5;
const CODEX_IDLE_SECONDS: u64 = 45;

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
    #[serde(default = "default_hook_provider")]
    pub provider: String,
}

fn default_hook_provider() -> String {
    "claude".to_string()
}

#[derive(Serialize)]
struct HookProviderStatus {
    supported: bool,
    enabled: bool,
    reason: Option<&'static str>,
}

/// POST /api/notifications/register
pub async fn register_token(
    State(state): State<AppState>,
    Json(body): Json<TokenRequest>,
) -> StatusCode {
    info!(
        "registering push token: {}... (provider: {})",
        &body.token[..body.token.len().min(20)],
        body.push_provider
    );
    state
        .register_push_token(body.token, body.push_provider)
        .await;
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

/// POST /api/notifications/send - called by completion hooks when a task finishes.
pub async fn send_notification(
    State(state): State<AppState>,
    body: Option<Json<SendRequest>>,
) -> Result<StatusCode, (StatusCode, String)> {
    let tokens = state.get_push_tokens().await;
    if tokens.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "no push tokens registered".to_string(),
        ));
    }

    let (session, msg) = match body {
        Some(Json(b)) => {
            // Match cwd against tmux pane paths to find the session name
            let title = if !b.cwd.is_empty() {
                resolve_session_name(&state, &b.cwd)
                    .await
                    .unwrap_or_else(|| b.session.clone())
            } else {
                b.session.clone()
            };
            let title = if title.is_empty() {
                "Session".to_string()
            } else {
                title
            };
            let body_text = if !b.body.is_empty() {
                b.body
            } else {
                "Task complete".to_string()
            };
            (title, body_text)
        }
        None => ("Session".to_string(), "Task complete".to_string()),
    };

    // Mark session as unread as a reliable fallback that works without APNs.
    if !session.is_empty() && session != "Session" {
        state.mark_session_unread(session.clone()).await;
    }

    state
        .sender
        .send(&tokens, &session, &msg, "", &session, "task_complete")
        .await;
    info!("sent push notification for session '{}'", session);
    Ok(StatusCode::OK)
}

/// POST /api/notifications/test
pub async fn test_notification(
    State(state): State<AppState>,
) -> Result<StatusCode, (StatusCode, String)> {
    let tokens = state.get_push_tokens().await;
    if tokens.is_empty() {
        return Err((
            StatusCode::BAD_REQUEST,
            "no push tokens registered".to_string(),
        ));
    }

    state.sender.send_test(&tokens).await;
    info!("sent test notification to {} token(s)", tokens.len());
    Ok(StatusCode::OK)
}

/// POST /api/notifications/hook - enable/disable provider-specific completion hooks.
pub async fn set_hook(
    State(state): State<AppState>,
    Json(body): Json<HookRequest>,
) -> Result<StatusCode, (StatusCode, String)> {
    let port = state.config.server.port;
    let token = &state.config.auth.token;

    match body.provider.trim().to_ascii_lowercase().as_str() {
        "claude" => match write_claude_hook(body.enabled, port, token) {
            Ok(_) => {
                info!(
                    "claude Stop hook {}",
                    if body.enabled { "enabled" } else { "disabled" }
                );
                Ok(StatusCode::OK)
            }
            Err(e) => {
                warn!("failed to update claude hook: {}", e);
                Err((StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
            }
        },
        "codex" => {
            if body.enabled {
                write_codex_watcher_enabled(true)?;
                info!("codex completion watcher enabled");
                Ok(StatusCode::OK)
            } else {
                write_codex_watcher_enabled(false)?;
                info!("codex completion watcher disabled");
                Ok(StatusCode::OK)
            }
        }
        other => Err((
            StatusCode::BAD_REQUEST,
            format!("unsupported notification hook provider: {}", other),
        )),
    }
}

/// GET /api/notifications/debug
pub async fn debug_notifications(State(state): State<AppState>) -> Json<serde_json::Value> {
    let tokens = state.get_push_tokens().await;
    let claude_hook_enabled = is_claude_hook_enabled();
    let hooks = serde_json::json!({
        "claude": HookProviderStatus {
            supported: true,
            enabled: claude_hook_enabled,
            reason: None,
        },
        "codex": HookProviderStatus {
            supported: true,
            enabled: is_codex_watcher_enabled(),
            reason: Some("Uses Marmy's local tmux idle watcher because Codex has no Claude-style Stop hook configured"),
        },
    });
    Json(serde_json::json!({
        "configured": state.sender.is_configured(),
        "registered_tokens": tokens.len(),
        "hook_enabled": claude_hook_enabled,
        "hooks": hooks,
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
    let session_ids: std::collections::HashSet<&str> =
        topology.sessions.iter().map(|s| s.id.as_str()).collect();

    let visible_panes: Vec<_> = topology
        .panes
        .iter()
        .filter(|p| !p.current_path.is_empty())
        .filter(|p| session_ids.contains(p.session_id.as_str()))
        .collect();

    // Strategy 1: pane path is a prefix of cwd (original behavior)
    let best = visible_panes
        .iter()
        .filter(|p| cwd_path.starts_with(&p.current_path))
        .max_by_key(|p| p.current_path.len());

    if let Some(pane) = best {
        return topology
            .sessions
            .iter()
            .find(|s| s.id == pane.session_id)
            .map(|s| s.name.clone());
    }

    // Strategy 2: cwd is a prefix of a pane path (reverse match)
    let reverse = visible_panes
        .iter()
        .filter(|p| std::path::Path::new(&p.current_path).starts_with(cwd_path))
        .max_by_key(|p| p.current_path.len());

    if let Some(pane) = reverse {
        return topology
            .sessions
            .iter()
            .find(|s| s.id == pane.session_id)
            .map(|s| s.name.clone());
    }

    // Strategy 3: if there's only one non-manager session, it's almost certainly the right one
    let user_sessions: Vec<_> = topology
        .sessions
        .iter()
        .filter(|s| s.name != "sessions-manager")
        .collect();
    if user_sessions.len() == 1 {
        return Some(user_sessions[0].name.clone());
    }

    None
}

fn is_claude_hook_enabled() -> bool {
    let settings = read_settings();
    settings
        .get("hooks")
        .and_then(|h| h.get("Stop"))
        .and_then(|s| s.as_array())
        .map(|arr| !arr.is_empty())
        .unwrap_or(false)
}

/// If the hook is already enabled, rewrite it with current port/token.
/// Call on agent startup so deploying a new agent version updates the hook.
pub fn refresh_hook_if_enabled(port: u16, token: &str) {
    if is_claude_hook_enabled() {
        if let Err(e) = write_claude_hook(true, port, token) {
            tracing::warn!("failed to refresh notification hook: {}", e);
        } else {
            tracing::info!("refreshed notification hook with current config");
        }
    }
}

// --- Codex tmux idle watcher ---

#[derive(Default)]
struct CodexPaneWatch {
    last_hash: u64,
    last_changed: Option<Instant>,
    last_notified_hash: Option<u64>,
    last_notified_at: Option<Instant>,
    saw_activity: bool,
}

pub fn spawn_codex_watcher(state: AppState) {
    tokio::spawn(async move {
        let poll_interval = Duration::from_secs(CODEX_WATCHER_POLL_SECONDS);
        let idle_after = Duration::from_secs(CODEX_IDLE_SECONDS);
        let cooldown = Duration::from_secs(state.config.notifications.cooldown_seconds);
        let mut watched: HashMap<String, CodexPaneWatch> = HashMap::new();

        loop {
            tokio::time::sleep(poll_interval).await;

            if !is_codex_watcher_enabled() {
                watched.clear();
                continue;
            }

            if let Err(e) = check_codex_panes(&state, &mut watched, idle_after, cooldown).await {
                tracing::warn!("codex notification watcher check failed: {}", e);
            }
        }
    });
}

async fn check_codex_panes(
    state: &AppState,
    watched: &mut HashMap<String, CodexPaneWatch>,
    idle_after: Duration,
    cooldown: Duration,
) -> anyhow::Result<()> {
    let topology = state.get_topology().await?;
    let sessions_by_id: HashMap<&str, &str> = topology
        .sessions
        .iter()
        .map(|session| (session.id.as_str(), session.name.as_str()))
        .collect();

    let codex_panes: Vec<_> = topology
        .panes
        .iter()
        .filter(|pane| is_codex_pane_command(&pane.current_command))
        .collect();

    watched.retain(|pane_id, _| codex_panes.iter().any(|pane| pane.id == *pane_id));

    for pane in codex_panes {
        let content = state.tmux.capture_pane(&pane.id, false).await?;
        let content_hash = stable_hash(&content);
        let now = Instant::now();
        let watch = watched.entry(pane.id.clone()).or_default();

        if watch.last_hash == 0 {
            watch.last_hash = content_hash;
            watch.last_changed = Some(now);
            continue;
        }

        if watch.last_hash != content_hash {
            watch.last_hash = content_hash;
            watch.last_changed = Some(now);
            watch.saw_activity = true;
            continue;
        }

        if !watch.saw_activity || watch.last_notified_hash == Some(content_hash) {
            continue;
        }

        let Some(last_changed) = watch.last_changed else {
            continue;
        };

        if now.duration_since(last_changed) < idle_after {
            continue;
        }

        if watch
            .last_notified_at
            .map_or(false, |sent_at| now.duration_since(sent_at) < cooldown)
        {
            continue;
        }

        let session_name = sessions_by_id
            .get(pane.session_id.as_str())
            .copied()
            .unwrap_or("Codex");
        send_task_complete(state, session_name, &pane.id, "Codex task complete").await;
        watch.last_notified_hash = Some(content_hash);
        watch.last_notified_at = Some(now);
        watch.saw_activity = false;
    }

    Ok(())
}

async fn send_task_complete(state: &AppState, session_name: &str, pane_id: &str, body: &str) {
    let tokens = state.get_push_tokens().await;
    if tokens.is_empty() {
        return;
    }

    if !session_name.is_empty() && session_name != "Codex" {
        state.mark_session_unread(session_name.to_string()).await;
    }

    state
        .sender
        .send(
            &tokens,
            session_name,
            body,
            pane_id,
            session_name,
            "task_complete",
        )
        .await;
    info!(
        "sent codex watcher push notification for '{}'",
        session_name
    );
}

fn stable_hash(content: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    content.hash(&mut hasher);
    hasher.finish()
}

fn is_codex_pane_command(command: &str) -> bool {
    let command = command.trim().to_ascii_lowercase();
    command == "codex" || command.ends_with("/codex") || command.contains("codex")
}

fn hook_state_path() -> PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| PathBuf::from("~"))
        .join(".marmy")
        .join("notification_hooks.json")
}

fn is_codex_watcher_enabled() -> bool {
    let path = hook_state_path();
    let Ok(content) = std::fs::read_to_string(path) else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&content) else {
        return false;
    };
    value
        .get("codex_watcher_enabled")
        .and_then(|enabled| enabled.as_bool())
        .unwrap_or(false)
}

fn write_codex_watcher_enabled(enabled: bool) -> Result<(), (StatusCode, String)> {
    let path = hook_state_path();
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    }
    let content = serde_json::to_string_pretty(&serde_json::json!({
        "codex_watcher_enabled": enabled,
    }))
    .map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))?;
    std::fs::write(path, content).map_err(|e| (StatusCode::INTERNAL_SERVER_ERROR, e.to_string()))
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
        settings
            .get("hooks")
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
        let cmd = settings["hooks"]["Stop"][0]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        assert!(cmd.contains("9876"));
        assert!(cmd.contains("test-token"));
        assert!(cmd.contains("curl"));
    }

    #[test]
    fn hook_enable_embeds_correct_port_and_token() {
        let mut settings = serde_json::json!({});
        build_hook_json(&mut settings, true, 4444, "my-secret");

        let cmd = settings["hooks"]["Stop"][0]["hooks"][0]["command"]
            .as_str()
            .unwrap();
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

        let cmd = settings["hooks"]["Stop"][0]["hooks"][0]["command"]
            .as_str()
            .unwrap();
        assert!(cmd.contains("new-token"));
        assert!(!cmd.contains("old-token"));
    }

    #[test]
    fn hook_timeout_is_5_seconds() {
        let mut settings = serde_json::json!({});
        build_hook_json(&mut settings, true, 9876, "tok");

        let timeout = settings["hooks"]["Stop"][0]["hooks"][0]["timeout"]
            .as_u64()
            .unwrap();
        assert_eq!(timeout, 5);
    }

    #[test]
    fn codex_command_detection_accepts_codex_processes() {
        assert!(super::is_codex_pane_command("codex"));
        assert!(super::is_codex_pane_command("/usr/local/bin/codex"));
        assert!(super::is_codex_pane_command("codex-tui"));
    }

    #[test]
    fn codex_command_detection_rejects_other_processes() {
        assert!(!super::is_codex_pane_command("bash"));
        assert!(!super::is_codex_pane_command("claude"));
        assert!(!super::is_codex_pane_command(""));
    }
}
